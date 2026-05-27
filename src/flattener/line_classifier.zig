const std = @import("std");
const common_instruction = @import("../common/instruction.zig");
const common_signature = @import("../common/signature.zig");

pub const LineKind = enum {
    blank_or_comment,
    version,
    def,
    const_decl,
    import_decl,
    loc_hint,
    func_decl,
    ffi_wrapper_decl,
    extern_decl,
    export_decl,
    test_decl,
    label,
    macro_start,
    macro_end,
    rep_start,
    rep_end,
    if_start,
    else_,
    if_end,
    expand,
    instruction,
    native,
    unknown,
};

pub const InstructionForm = enum {
    alloc,
    stack_alloc,
    load,
    store,
    atomic_load,
    atomic_store,
    cmpxchg,
    atomic_rmw,
    fence,
    borrow,
    move_,
    release,
    assign,
    op,
    ptr_add,
    jmp,
    br,
    br_null,
    call,
    call_indirect,
    try_,
    panic,
    panic_msg,
    return_,
    take,
    raw_cast,
    assume_safe,
    assume_borrow,
    unknown,
};

pub const ClassifiedLine = struct {
    kind: LineKind,
    inst_form: ?InstructionForm = null,
    raw: []const u8,
    trimmed: []const u8,
    parts: [6][]const u8 = .{ "", "", "", "", "", "" },
    part_count: u8 = 0,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isQualifiedDefName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '.' or name[name.len - 1] == '.') return false;

    var segment_start: usize = 0;
    var idx: usize = 0;
    while (idx < name.len) : (idx += 1) {
        if (name[idx] != '.') continue;
        if (idx == segment_start) return false;
        if (!isIdentStart(name[segment_start])) return false;
        var seg_idx = segment_start + 1;
        while (seg_idx < idx) : (seg_idx += 1) {
            if (!isIdentChar(name[seg_idx])) return false;
        }
        segment_start = idx + 1;
    }

    if (segment_start >= name.len) return false;
    if (!isIdentStart(name[segment_start])) return false;
    var seg_idx = segment_start + 1;
    while (seg_idx < name.len) : (seg_idx += 1) {
        if (!isIdentChar(name[seg_idx])) return false;
    }
    return true;
}

fn containsToken(tokens: []const []const u8, needle: []const u8) bool {
    for (tokens) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn startsWithWord(s: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, s, word)) return false;
    if (s.len == word.len) return true;
    const next = s[word.len];
    return std.ascii.isWhitespace(next) or next == '(' or next == '[' or next == ':' or next == '=' or next == '@' or next == '-';
}

fn parseTestModifierPrefix(body: []const u8) ?[]const u8 {
    var rest = std.mem.trimLeft(u8, body, " \t");
    while (rest.len != 0 and rest[0] != '"') {
        const token_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const token = rest[0..token_end];
        if (std.mem.eql(u8, token, "ignored") or std.mem.eql(u8, token, "should_panic")) {
            rest = std.mem.trimLeft(u8, rest[token_end..], " \t");
            continue;
        }
        break;
    }
    return rest;
}

fn makeLine(kind: LineKind, raw: []const u8, trimmed: []const u8) ClassifiedLine {
    return .{
        .kind = kind,
        .raw = raw,
        .trimmed = trimmed,
    };
}

fn addPart(line: *ClassifiedLine, index: usize, value: []const u8) void {
    line.parts[index] = value;
    const count: u8 = @intCast(index + 1);
    if (line.part_count < count) line.part_count = count;
}

fn splitFirstWord(text: []const u8) struct { word: []const u8, rest: []const u8 } {
    var i: usize = 0;
    while (i < text.len and !std.ascii.isWhitespace(text[i])) : (i += 1) {}
    var j: usize = i;
    while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
    return .{ .word = text[0..i], .rest = text[j..] };
}

fn splitAssignment(text: []const u8) ?struct { lhs: []const u8, rhs: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    if (eq + 1 < text.len and text[eq + 1] == '=') return null;
    if (eq > 0 and text[eq - 1] == '=') return null;
    return .{
        .lhs = text[0..eq],
        .rhs = text[eq + 1 ..],
    };
}

fn parseConstDecl(raw: []const u8, trimmed: []const u8) ?ClassifiedLine {
    if (!startsWithWord(trimmed, "@const")) return null;

    const after = std.mem.trimLeft(u8, trimmed["@const".len..], " \t");
    const eq = std.mem.indexOfScalar(u8, after, '=') orelse return null;
    const name = std.mem.trim(u8, after[0..eq], " \t");
    const literal = std.mem.trim(u8, after[eq + 1 ..], " \t");
    if (name.len == 0 or literal.len == 0) return null;
    if (!isIdentStart(name[0])) return null;
    for (name[1..]) |c| {
        if (!isIdentChar(c)) return null;
    }

    var out = makeLine(.const_decl, raw, trimmed);
    addPart(&out, 0, name);
    addPart(&out, 1, literal);
    return out;
}

fn parseAddress(text: []const u8) ?struct { base: []const u8, offset: []const u8 } {
    const plus = std.mem.indexOfScalar(u8, text, '+') orelse return null;
    const base = std.mem.trim(u8, text[0..plus], " \t");
    const offset = std.mem.trim(u8, text[plus + 1 ..], " \t");
    if (base.len == 0 or offset.len == 0) return null;
    return .{ .base = base, .offset = offset };
}

fn parseCommaPair(text: []const u8) ?struct { left: []const u8, right: []const u8 } {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const left = std.mem.trim(u8, text[0..comma], " \t");
    const right = std.mem.trim(u8, text[comma + 1 ..], " \t");
    if (left.len == 0 or right.len == 0) return null;
    return .{ .left = left, .right = right };
}

fn parseCommaTriple(text: []const u8) ?struct { first: []const u8, second: []const u8, third: []const u8 } {
    const first_comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const first = std.mem.trim(u8, text[0..first_comma], " \t");
    const rest = std.mem.trimLeft(u8, text[first_comma + 1 ..], " \t");
    const second_comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    const second = std.mem.trim(u8, rest[0..second_comma], " \t");
    const third = std.mem.trim(u8, rest[second_comma + 1 ..], " \t");
    if (first.len == 0 or second.len == 0 or third.len == 0) return null;
    return .{ .first = first, .second = second, .third = third };
}

const TypedSuffix = struct { body: []const u8, ty: []const u8 };

fn splitTrailingType(text: []const u8) ?TypedSuffix {
    const trimmed = std.mem.trim(u8, text, " \t");
    const idx = std.mem.lastIndexOf(u8, trimmed, " as ") orelse return null;
    const body = std.mem.trimRight(u8, trimmed[0..idx], " \t");
    const ty = std.mem.trim(u8, trimmed[idx + 4 ..], " \t");
    if (body.len == 0 or ty.len == 0) return null;
    return .{ .body = body, .ty = ty };
}

fn splitPrimitiveTypedValue(text: []const u8) ?TypedSuffix {
    const suffix = splitTrailingType(text) orelse return null;
    if (common_signature.parsePrimType(suffix.ty)) |_| {
        const body = splitFirstWord(suffix.body);
        if (body.word.len != 0 and std.mem.trim(u8, body.rest, " \t").len == 0) return suffix;
    } else |_| {}
    return null;
}

pub fn collectNativeRegisterNames(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var names = std.ArrayList([]const u8).init(allocator);
    errdefer names.deinit();

    var idx: usize = 0;
    while (idx < text.len) {
        if (text[idx] == '"') {
            idx += 1;
            while (idx < text.len) : (idx += 1) {
                if (text[idx] == '\\' and idx + 1 < text.len) {
                    idx += 1;
                    continue;
                }
                if (text[idx] == '"') {
                    idx += 1;
                    break;
                }
            }
            continue;
        }

        if (!isIdentStart(text[idx])) {
            idx += 1;
            continue;
        }

        const prev = if (idx == 0) 0 else text[idx - 1];
        const start = idx;
        idx += 1;
        while (idx < text.len and isIdentChar(text[idx])) : (idx += 1) {}
        const token = text[start..idx];

        if (prev == '@' or prev == '%') continue;
        if (!containsToken(names.items, token)) {
            try names.append(token);
        }
    }

    return try names.toOwnedSlice();
}

fn parseFunctionHeader(
    raw: []const u8,
    trimmed: []const u8,
    prefix: []const u8,
    kind: LineKind,
    require_colon: bool,
) ?ClassifiedLine {
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;

    const body = if (require_colon) blk: {
        if (trimmed.len <= prefix.len or trimmed[trimmed.len - 1] != ':') return null;
        break :blk trimmed[prefix.len .. trimmed.len - 1];
    } else blk: {
        const body_raw = trimmed[prefix.len..];
        break :blk std.mem.trimRight(u8, body_raw, ": \t\r");
    };

    const effective_body = if (kind == .test_decl) blk: {
        const modifiers_rest = parseTestModifierPrefix(body) orelse return null;
        break :blk modifiers_rest;
    } else body;

    const after_name = std.mem.trimLeft(u8, effective_body, " \t");
    const open = std.mem.indexOfScalar(u8, after_name, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, after_name, ')') orelse return null;
    if (close < open) return null;

    const name_part = std.mem.trim(u8, after_name[0..open], " \t");
    if (name_part.len == 0) return null;

    // For @test functions, allow string literals as names
    const name = if (kind == .test_decl and name_part[0] == '"') blk: {
        const end_quote = std.mem.indexOfScalarPos(u8, name_part, 1, '"') orelse return null;
        break :blk name_part[0 .. end_quote + 1];
    } else blk: {
        if (!isIdentStart(name_part[0])) return null;
        for (name_part[1..]) |c| {
            if (!isIdentChar(c)) return null;
        }
        break :blk name_part;
    };

    const params = std.mem.trim(u8, after_name[open + 1 .. close], " \t");
    const tail = std.mem.trim(u8, after_name[close + 1 ..], " \t");

    var out = makeLine(kind, raw, trimmed);
    addPart(&out, 0, name);
    addPart(&out, 1, params);
    if (tail.len != 0) {
        if (!std.mem.startsWith(u8, tail, "->")) return null;
        addPart(&out, 2, std.mem.trim(u8, tail[2..], " \t"));
    }
    return out;
}

fn parseLocHint(raw: []const u8, trimmed: []const u8) ?ClassifiedLine {
    if (!std.mem.startsWith(u8, trimmed, "#loc")) return null;

    const after = std.mem.trimLeft(u8, trimmed["#loc".len..], " \t");
    if (after.len < 6 or after[0] != '"') return null;

    const end_quote = std.mem.indexOfScalarPos(u8, after, 1, '"') orelse return null;
    const file = after[1..end_quote];
    const rest = std.mem.trimLeft(u8, after[end_quote + 1 ..], " \t");
    if (rest.len < 2 or rest[0] != ':') return null;

    const after_file = rest[1..];
    const line_sep = std.mem.indexOfScalar(u8, after_file, ':') orelse return null;
    const line_text = std.mem.trim(u8, after_file[0..line_sep], " \t");
    const col_text = std.mem.trim(u8, after_file[line_sep + 1 ..], " \t");
    if (line_text.len == 0 or col_text.len == 0) return null;

    var out = makeLine(.loc_hint, raw, trimmed);
    addPart(&out, 0, file);
    addPart(&out, 1, line_text);
    addPart(&out, 2, col_text);
    return out;
}

fn parseImport(raw: []const u8, trimmed: []const u8) ?ClassifiedLine {
    if (!std.mem.startsWith(u8, trimmed, "@import")) return null;

    const after = std.mem.trimLeft(u8, trimmed["@import".len..], " \t");
    if (after.len < 2 or after[0] != '"') return null;
    const end_quote = std.mem.indexOfScalarPos(u8, after, 1, '"') orelse return null;
    const path = after[1..end_quote];
    const rest = std.mem.trim(u8, after[end_quote + 1 ..], " \t\r");
    if (path.len == 0 or rest.len != 0) return null;

    var out = makeLine(.import_decl, raw, trimmed);
    addPart(&out, 0, path);
    return out;
}

fn classifyAssignment(line: *ClassifiedLine, lhs_text: []const u8, rhs_text: []const u8) bool {
    const lhs = std.mem.trim(u8, lhs_text, " \t");
    const rhs = std.mem.trim(u8, rhs_text, " \t");
    if (lhs.len == 0 or rhs.len == 0) return false;

    const typed_rhs = splitPrimitiveTypedValue(rhs);
    const simple_rhs = if (typed_rhs) |typed| typed.body else rhs;

    if (std.mem.startsWith(u8, simple_rhs, "*")) {
        const source = std.mem.trim(u8, simple_rhs[1..], " \t");
        if (source.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .raw_cast;
        addPart(line, 0, lhs);
        addPart(line, 1, source);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "assume_safe")) {
        const rest = std.mem.trimLeft(u8, simple_rhs["assume_safe".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .assume_safe;
        addPart(line, 0, lhs);
        addPart(line, 1, rest);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "assume_borrow")) {
        const rest = std.mem.trimLeft(u8, simple_rhs["assume_borrow".len..], " \t");
        if (rest.len == 0) return false;
        const pair = parseCommaPair(rest);
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .assume_borrow;
        if (pair) |p| {
            addPart(line, 0, lhs);
            addPart(line, 1, p.left);
            addPart(line, 2, p.right);
        } else {
            addPart(line, 0, lhs);
            addPart(line, 1, rest);
        }
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "call_indirect")) {
        const rest = std.mem.trimLeft(u8, simple_rhs["call_indirect".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .call_indirect;
        addPart(line, 0, lhs);
        addPart(line, 1, rest);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "ptr_add")) {
        const rest = std.mem.trimLeft(u8, simple_rhs["ptr_add".len..], " \t");
        const pair = parseCommaPair(rest) orelse return false;
        if (pair.left.len == 0 or pair.right.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .ptr_add;
        addPart(line, 0, lhs);
        addPart(line, 1, pair.left);
        addPart(line, 2, pair.right);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "call")) {
        const rest = std.mem.trimLeft(u8, simple_rhs["call".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .call;
        addPart(line, 0, lhs);
        addPart(line, 1, rest);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "atomic_load")) {
        const rest = std.mem.trimLeft(u8, simple_rhs["atomic_load".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .atomic_load;
        addPart(line, 0, lhs);
        addPart(line, 1, rest);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "cmpxchg")) {
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .cmpxchg;
        addPart(line, 0, lhs);
        addPart(line, 1, simple_rhs);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "atomic_rmw_")) {
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .atomic_rmw;
        addPart(line, 0, lhs);
        addPart(line, 1, simple_rhs);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "?")) {
        const rest = std.mem.trim(u8, simple_rhs["?".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .try_;
        addPart(line, 0, lhs);
        addPart(line, 1, rest);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "&")) {
        const source = std.mem.trim(u8, simple_rhs["&".len..], " \t");
        if (source.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .borrow;
        addPart(line, 0, lhs);
        addPart(line, 1, "read");
        addPart(line, 2, source);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "alloc ")) {
        const size = std.mem.trim(u8, simple_rhs["alloc ".len..], " \t");
        if (size.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .alloc;
        addPart(line, 0, lhs);
        addPart(line, 1, size);
        return true;
    }

    if (std.mem.startsWith(u8, simple_rhs, "stack_alloc ")) {
        const size = std.mem.trim(u8, simple_rhs["stack_alloc ".len..], " \t");
        if (size.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .stack_alloc;
        addPart(line, 0, lhs);
        addPart(line, 1, size);
        return true;
    }

    if (std.mem.startsWith(u8, rhs, "load ")) {
        var address = std.mem.trim(u8, rhs["load ".len..], " \t");
        var ty_text: []const u8 = "";
        if (splitTrailingType(address)) |suffix| {
            address = suffix.body;
            ty_text = suffix.ty;
        }
        const parsed = parseAddress(address) orelse return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .load;
        addPart(line, 0, lhs);
        addPart(line, 1, parsed.base);
        addPart(line, 2, parsed.offset);
        if (ty_text.len != 0) addPart(line, 3, ty_text);
        return true;
    }

    if (std.mem.startsWith(u8, rhs, "take ")) {
        var address = std.mem.trim(u8, rhs["take ".len..], " \t");
        var ty_text: []const u8 = "";
        if (splitTrailingType(address)) |suffix| {
            address = suffix.body;
            ty_text = suffix.ty;
        }
        const parsed = parseAddress(address) orelse return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .take;
        addPart(line, 0, lhs);
        addPart(line, 1, parsed.base);
        addPart(line, 2, parsed.offset);
        if (ty_text.len != 0) addPart(line, 3, ty_text);
        return true;
    }

    const op = splitFirstWord(rhs);
    if (op.word.len != 0) {
        if (common_instruction.parseOpKind(op.word)) |op_kind| {
            line.* = makeLine(.instruction, line.raw, line.trimmed);
            line.inst_form = .op;
            addPart(line, 0, lhs);
            addPart(line, 1, op.word);

            const rest_trimmed = std.mem.trim(u8, op.rest, " \t");
            const typed = if (std.mem.lastIndexOf(u8, rest_trimmed, " as ")) |idx| blk: {
                const body = std.mem.trimRight(u8, rest_trimmed[0..idx], " \t");
                const ty = std.mem.trim(u8, rest_trimmed[idx + 4 ..], " \t");
                if (ty.len == 0) break :blk null;
                break :blk .{ .body = body, .ty = ty };
            } else null;

            switch (op_kind) {
                .neg, .not, .fneg, .trunc, .zext, .sext, .fptosi, .sitofp, .uitofp, .fptrunc, .fpext, .bitcast => {
                    const body = if (typed) |suffix| suffix.body else rest_trimmed;
                    if (body.len == 0) return false;
                    addPart(line, 2, body);
                    if (typed) |suffix| addPart(line, 3, suffix.ty);
                    return true;
                },
                .extract_lane => {
                    const pair = parseCommaPair(rest_trimmed) orelse return false;
                    addPart(line, 2, pair.left);
                    addPart(line, 3, pair.right);
                    return true;
                },
                .insert_lane, .shuffle_v128 => {
                    const triple = parseCommaTriple(rest_trimmed) orelse return false;
                    addPart(line, 2, triple.first);
                    addPart(line, 3, triple.second);
                    addPart(line, 4, triple.third);
                    return true;
                },
                else => {
                    const pair = parseCommaPair(rest_trimmed) orelse return false;
                    addPart(line, 2, pair.left);
                    addPart(line, 3, pair.right);
                    return true;
                },
            }
        }
    }

    if (op.word.len != 0 and std.mem.trim(u8, op.rest, " \t").len == 0) {
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .assign;
        addPart(line, 0, lhs);
        addPart(line, 1, op.word);
        return true;
    }

    if (typed_rhs) |typed| {
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .assign;
        addPart(line, 0, lhs);
        addPart(line, 1, typed.body);
        return true;
    }

    return false;
}

fn classifyDirect(line: *ClassifiedLine, trimmed: []const u8) bool {
    if (trimmed.len != 0 and trimmed[0] == '!') {
        const rest = std.mem.trim(u8, trimmed[1..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .release;
        addPart(line, 0, rest);
        return true;
    }

    if (trimmed.len != 0 and trimmed[0] == '^') {
        const rest = std.mem.trim(u8, trimmed[1..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .move_;
        addPart(line, 0, rest);
        return true;
    }

    if (startsWithWord(trimmed, "store")) {
        const rest = std.mem.trimLeft(u8, trimmed["store".len..], " \t");
        const pair = parseCommaPair(rest) orelse return false;
        const addr = parseAddress(pair.left) orelse return false;
        var value = pair.right;
        var ty_text: []const u8 = "";
        if (splitTrailingType(value)) |suffix| {
            value = suffix.body;
            ty_text = suffix.ty;
        }
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .store;
        addPart(line, 0, addr.base);
        addPart(line, 1, addr.offset);
        addPart(line, 2, value);
        if (ty_text.len != 0) addPart(line, 3, ty_text);
        return true;
    }

    if (startsWithWord(trimmed, "atomic_store")) {
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .atomic_store;
        addPart(line, 0, trimmed);
        return true;
    }

    if (startsWithWord(trimmed, "br_null")) {
        const rest = std.mem.trimLeft(u8, trimmed["br_null".len..], " \t");
        const pair = parseCommaPair(std.mem.trimLeft(u8, rest, " \t")) orelse return false;
        const arrow = std.mem.indexOf(u8, pair.left, "->") orelse return false;
        const reg = std.mem.trim(u8, pair.left[0..arrow], " \t");
        const label = std.mem.trim(u8, pair.left[arrow + 2 ..], " \t");
        if (reg.len == 0 or label.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .br_null;
        addPart(line, 0, reg);
        addPart(line, 1, label);
        addPart(line, 2, pair.right);
        return true;
    }

    if (startsWithWord(trimmed, "br")) {
        const rest = std.mem.trimLeft(u8, trimmed["br".len..], " \t");
        const arrow = std.mem.indexOf(u8, rest, "->") orelse return false;
        const cond = std.mem.trim(u8, rest[0..arrow], " \t");
        const pair = parseCommaPair(std.mem.trimLeft(u8, rest[arrow + 2 ..], " \t")) orelse return false;
        if (cond.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .br;
        addPart(line, 0, cond);
        addPart(line, 1, pair.left);
        addPart(line, 2, pair.right);
        return true;
    }

    if (startsWithWord(trimmed, "jmp")) {
        const rest = std.mem.trimLeft(u8, trimmed["jmp".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .jmp;
        addPart(line, 0, rest);
        return true;
    }

    if (startsWithWord(trimmed, "call_indirect")) {
        const rest = std.mem.trimLeft(u8, trimmed["call_indirect".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .call_indirect;
        addPart(line, 0, rest);
        return true;
    }

    if (startsWithWord(trimmed, "call")) {
        const rest = std.mem.trimLeft(u8, trimmed["call".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .call;
        addPart(line, 0, rest);
        return true;
    }

    if (startsWithWord(trimmed, "panic_msg")) {
        const rest = std.mem.trimLeft(u8, trimmed["panic_msg".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .panic_msg;
        addPart(line, 0, rest);
        return true;
    }

    if (startsWithWord(trimmed, "?")) {
        const rest = std.mem.trim(u8, trimmed["?".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .try_;
        addPart(line, 0, rest);
        return true;
    }

    if (startsWithWord(trimmed, "panic")) {
        const rest = std.mem.trimLeft(u8, trimmed["panic".len..], " \t");
        if (rest.len == 0) return false;
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .panic;
        addPart(line, 0, rest);
        return true;
    }

    if (std.mem.startsWith(u8, trimmed, "fence")) {
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .fence;
        addPart(line, 0, trimmed);
        return true;
    }

    if (startsWithWord(trimmed, "return")) {
        const rest = std.mem.trimLeft(u8, trimmed["return".len..], " \t");
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .return_;
        if (rest.len != 0) addPart(line, 0, rest);
        return true;
    }

    if (startsWithWord(trimmed, "ret")) {
        const rest = std.mem.trimLeft(u8, trimmed["ret".len..], " \t");
        line.* = makeLine(.instruction, line.raw, line.trimmed);
        line.inst_form = .return_;
        if (rest.len != 0) addPart(line, 0, rest);
        return true;
    }

    return false;
}

pub fn classifyLine(line: []const u8) ClassifiedLine {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//")) {
        return makeLine(.blank_or_comment, line, trimmed);
    }

    if (trimmed.len >= 2 and trimmed[0] == '$' and trimmed[trimmed.len - 1] == '$') {
        var out = makeLine(.native, line, trimmed);
        addPart(&out, 0, trimmed[1 .. trimmed.len - 1]);
        return out;
    }

    if (std.mem.startsWith(u8, trimmed, "#version")) {
        const after = std.mem.trimLeft(u8, trimmed["#version".len..], " \t");
        if (after.len == 0) return makeLine(.unknown, line, trimmed);
        var i: usize = 0;
        while (i < after.len and std.ascii.isDigit(after[i])) : (i += 1) {}
        if (i == 0 or std.mem.trim(u8, after[i..], " \t").len != 0) return makeLine(.unknown, line, trimmed);
        var out = makeLine(.version, line, trimmed);
        addPart(&out, 0, after[0..i]);
        return out;
    }

    if (std.mem.startsWith(u8, trimmed, "#def")) {
        const after = std.mem.trimLeft(u8, trimmed["#def".len..], " \t");
        const eq = std.mem.indexOfScalar(u8, after, '=') orelse return makeLine(.unknown, line, trimmed);
        const name = std.mem.trim(u8, after[0..eq], " \t");
        const value = std.mem.trim(u8, after[eq + 1 ..], " \t");
        if (name.len == 0 or value.len == 0) return makeLine(.unknown, line, trimmed);
        if (!isQualifiedDefName(name)) return makeLine(.unknown, line, trimmed);
        var out = makeLine(.def, line, trimmed);
        addPart(&out, 0, name);
        addPart(&out, 1, value);
        return out;
    }

    if (parseConstDecl(line, trimmed)) |out| return out;

    if (parseLocHint(line, trimmed)) |out| return out;
    if (parseImport(line, trimmed)) |out| return out;

    if (parseFunctionHeader(line, trimmed, "@ffi_wrapper", .ffi_wrapper_decl, true)) |out| return out;
    if (parseFunctionHeader(line, trimmed, "@extern", .extern_decl, false)) |out| return out;
    if (parseFunctionHeader(line, trimmed, "@export", .export_decl, true)) |out| return out;
    if (parseFunctionHeader(line, trimmed, "@test", .test_decl, true)) |out| return out;
    if (parseFunctionHeader(line, trimmed, "@", .func_decl, true)) |out| return out;

    if (trimmed.len >= 3 and trimmed[0] == 'L' and trimmed[1] == '_' and trimmed[trimmed.len - 1] == ':') {
        const name = trimmed[0 .. trimmed.len - 1];
        if (name.len < 3) return makeLine(.unknown, line, trimmed);
        var valid = true;
        for (name[2..]) |c| {
            if (!isIdentChar(c)) {
                valid = false;
                break;
            }
        }
        if (valid) {
            var out = makeLine(.label, line, trimmed);
            addPart(&out, 0, name);
            return out;
        }
    }

    if (std.mem.startsWith(u8, trimmed, "[MACRO]")) {
        const after = std.mem.trimLeft(u8, trimmed["[MACRO]".len..], " \t");
        const pair = splitFirstWord(after);
        if (pair.word.len != 0) {
            var out = makeLine(.macro_start, line, trimmed);
            addPart(&out, 0, pair.word);
            addPart(&out, 1, pair.rest);
            return out;
        }
    }

    if (std.mem.eql(u8, trimmed, "[END_MACRO]")) {
        return makeLine(.macro_end, line, trimmed);
    }

    if (std.mem.startsWith(u8, trimmed, "[REP")) {
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return makeLine(.unknown, line, trimmed);
        const count = std.mem.trim(u8, trimmed["[REP".len..close], " \t");
        if (count.len == 0) return makeLine(.unknown, line, trimmed);
        var out = makeLine(.rep_start, line, trimmed);
        addPart(&out, 0, count);
        return out;
    }

    if (std.mem.eql(u8, trimmed, "[END_REP]")) {
        return makeLine(.rep_end, line, trimmed);
    }

    if (std.mem.startsWith(u8, trimmed, "[IF")) {
        const close = std.mem.indexOfScalar(u8, trimmed, ']') orelse return makeLine(.unknown, line, trimmed);
        const condition = std.mem.trim(u8, trimmed["[IF".len..close], " \t");
        if (condition.len == 0) return makeLine(.unknown, line, trimmed);
        var out = makeLine(.if_start, line, trimmed);
        addPart(&out, 0, condition);
        return out;
    }

    if (std.mem.eql(u8, trimmed, "[ELSE]")) {
        return makeLine(.else_, line, trimmed);
    }

    if (std.mem.eql(u8, trimmed, "[END_IF]")) {
        return makeLine(.if_end, line, trimmed);
    }

    if (std.mem.startsWith(u8, trimmed, "EXPAND")) {
        const after = std.mem.trimLeft(u8, trimmed["EXPAND".len..], " \t");
        const pair = splitFirstWord(after);
        if (pair.word.len != 0) {
            var out = makeLine(.expand, line, trimmed);
            addPart(&out, 0, pair.word);
            addPart(&out, 1, pair.rest);
            return out;
        }
    }

    const assignment = splitAssignment(trimmed);
    if (assignment) |assign| {
        var out = makeLine(.unknown, line, trimmed);
        if (classifyAssignment(&out, assign.lhs, assign.rhs)) return out;
    }

    var direct = makeLine(.unknown, line, trimmed);
    if (classifyDirect(&direct, trimmed)) return direct;

    return makeLine(.unknown, line, trimmed);
}

test "classify representative line families" {
    const def = classifyLine("#def SIZE = 16");
    try std.testing.expectEqual(LineKind.def, def.kind);
    try std.testing.expectEqualStrings("SIZE", def.parts[0]);
    try std.testing.expectEqualStrings("16", def.parts[1]);

    const const_decl = classifyLine("@const HELLO = utf8:\"hello\"");
    try std.testing.expectEqual(LineKind.const_decl, const_decl.kind);
    try std.testing.expectEqualStrings("HELLO", const_decl.parts[0]);
    try std.testing.expectEqualStrings("utf8:\"hello\"", const_decl.parts[1]);

    const func = classifyLine("@sum(^list, t) -> i32:");
    try std.testing.expectEqual(LineKind.func_decl, func.kind);
    try std.testing.expectEqualStrings("sum", func.parts[0]);
    try std.testing.expectEqualStrings("^list, t", func.parts[1]);
    try std.testing.expectEqualStrings("i32", func.parts[2]);

    const ffi = classifyLine("@ffi_wrapper wrap(*ptr) -> ^ptr:");
    try std.testing.expectEqual(LineKind.ffi_wrapper_decl, ffi.kind);
    try std.testing.expectEqualStrings("wrap", ffi.parts[0]);

    const ext = classifyLine("@extern libc_malloc(size) -> *void");
    try std.testing.expectEqual(LineKind.extern_decl, ext.kind);
    try std.testing.expectEqualStrings("libc_malloc", ext.parts[0]);

    const test_decl = classifyLine("@test ignored should_panic \"panic path\"():");
    try std.testing.expectEqual(LineKind.test_decl, test_decl.kind);
    try std.testing.expectEqualStrings("\"panic path\"", test_decl.parts[0]);

    const label = classifyLine("L_LOOP:");
    try std.testing.expectEqual(LineKind.label, label.kind);
    try std.testing.expectEqualStrings("L_LOOP", label.parts[0]);

    const alloc = classifyLine("node = alloc 8");
    try std.testing.expectEqual(LineKind.instruction, alloc.kind);
    try std.testing.expectEqual(InstructionForm.alloc, alloc.inst_form.?);
    try std.testing.expectEqualStrings("node", alloc.parts[0]);
    try std.testing.expectEqualStrings("8", alloc.parts[1]);

    const loc = classifyLine("#loc \"main.rs\":42:7");
    try std.testing.expectEqual(LineKind.loc_hint, loc.kind);
    try std.testing.expectEqualStrings("main.rs", loc.parts[0]);
    try std.testing.expectEqualStrings("42", loc.parts[1]);
    try std.testing.expectEqualStrings("7", loc.parts[2]);

    const import = classifyLine("@import \"sa_std/io/print.sai\"");
    try std.testing.expectEqual(LineKind.import_decl, import.kind);
    try std.testing.expectEqualStrings("sa_std/io/print.sai", import.parts[0]);

    const raw = classifyLine("raw = *safe");
    try std.testing.expectEqual(InstructionForm.raw_cast, raw.inst_form.?);

    const assume = classifyLine("safe = assume_safe raw");
    try std.testing.expectEqual(InstructionForm.assume_safe, assume.inst_form.?);

    const typed_assign = classifyLine("map = 0 as ptr");
    try std.testing.expectEqual(InstructionForm.assign, typed_assign.inst_form.?);
    try std.testing.expectEqualStrings("0", typed_assign.parts[1]);

    const borrow = classifyLine("view = assume_borrow raw, mut");
    try std.testing.expectEqual(InstructionForm.assume_borrow, borrow.inst_form.?);

    const panic = classifyLine("panic(7)");
    try std.testing.expectEqual(LineKind.instruction, panic.kind);
    try std.testing.expectEqual(InstructionForm.panic, panic.inst_form.?);

    const panic_msg = classifyLine("panic_msg(7, *msg, len)");
    try std.testing.expectEqual(LineKind.instruction, panic_msg.kind);
    try std.testing.expectEqual(InstructionForm.panic_msg, panic_msg.inst_form.?);

    const atomic_load = classifyLine("value = atomic_load ptr+0 acquire");
    try std.testing.expectEqual(InstructionForm.atomic_load, atomic_load.inst_form.?);

    const atomic_store = classifyLine("atomic_store ptr+0, value release");
    try std.testing.expectEqual(InstructionForm.atomic_store, atomic_store.inst_form.?);

    const sgt = classifyLine("cmp = sgt lhs, rhs");
    try std.testing.expectEqual(InstructionForm.op, sgt.inst_form.?);
    try std.testing.expectEqualStrings("sgt", sgt.parts[1]);

    const sle = classifyLine("cmp = sle lhs, rhs");
    try std.testing.expectEqual(InstructionForm.op, sle.inst_form.?);
    try std.testing.expectEqualStrings("sle", sle.parts[1]);

    const ult = classifyLine("cmp = ult lhs, rhs");
    try std.testing.expectEqual(InstructionForm.op, ult.inst_form.?);
    try std.testing.expectEqualStrings("ult", ult.parts[1]);

    const srem = classifyLine("rem = srem lhs, rhs");
    try std.testing.expectEqual(InstructionForm.op, srem.inst_form.?);
    try std.testing.expectEqualStrings("srem", srem.parts[1]);

    const zext = classifyLine("ret = zext ok");
    try std.testing.expectEqual(InstructionForm.op, zext.inst_form.?);
    try std.testing.expectEqualStrings("zext", zext.parts[1]);
    try std.testing.expectEqualStrings("ok", zext.parts[2]);

    const shuffle = classifyLine("out = shuffle_v128 a, b, mask");
    try std.testing.expectEqual(InstructionForm.op, shuffle.inst_form.?);
    try std.testing.expectEqualStrings("shuffle_v128", shuffle.parts[1]);
    try std.testing.expectEqualStrings("mask", shuffle.parts[4]);

    const cmpxchg = classifyLine("old, ok = cmpxchg ptr+0, expected, new acq_rel acquire");
    try std.testing.expectEqual(InstructionForm.cmpxchg, cmpxchg.inst_form.?);

    const rmw = classifyLine("old = atomic_rmw_add ptr+0, value seq_cst");
    try std.testing.expectEqual(InstructionForm.atomic_rmw, rmw.inst_form.?);

    const literal = classifyLine("i = 1");
    try std.testing.expectEqual(InstructionForm.assign, literal.inst_form.?);
    try std.testing.expectEqualStrings("i", literal.parts[0]);
    try std.testing.expectEqualStrings("1", literal.parts[1]);

    const rebinding = classifyLine("next = sum_next");
    try std.testing.expectEqual(InstructionForm.assign, rebinding.inst_form.?);
    try std.testing.expectEqualStrings("next", rebinding.parts[0]);
    try std.testing.expectEqualStrings("sum_next", rebinding.parts[1]);

    const fence = classifyLine("fence seq_cst");
    try std.testing.expectEqual(InstructionForm.fence, fence.inst_form.?);

    const store = classifyLine("store node+4, 0");
    try std.testing.expectEqual(LineKind.instruction, store.kind);
    try std.testing.expectEqual(InstructionForm.store, store.inst_form.?);
    try std.testing.expectEqualStrings("node", store.parts[0]);
    try std.testing.expectEqualStrings("4", store.parts[1]);
    try std.testing.expectEqualStrings("0", store.parts[2]);

    const typed_load = classifyLine("value = load node+8 as i64");
    try std.testing.expectEqual(InstructionForm.load, typed_load.inst_form.?);
    try std.testing.expectEqualStrings("i64", typed_load.parts[3]);

    const native = classifyLine("$const x = 1;$");
    try std.testing.expectEqual(LineKind.native, native.kind);
    try std.testing.expectEqualStrings("const x = 1;", native.parts[0]);
}

test "native register extraction keeps bare identifiers and skips llvm sigils" {
    const names = try collectNativeRegisterNames(std.testing.allocator, "call side(ptr foo, i32 bar) ; @glob %tmp \"skip me\" foo");
    defer std.testing.allocator.free(names);

    try std.testing.expectEqual(@as(usize, 6), names.len);
    try std.testing.expectEqualStrings("call", names[0]);
    try std.testing.expectEqualStrings("side", names[1]);
    try std.testing.expectEqualStrings("ptr", names[2]);
    try std.testing.expectEqualStrings("foo", names[3]);
    try std.testing.expectEqualStrings("i32", names[4]);
    try std.testing.expectEqualStrings("bar", names[5]);
}
