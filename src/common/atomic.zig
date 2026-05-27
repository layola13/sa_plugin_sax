const std = @import("std");
const sig = @import("signature.zig");

pub const AtomicOrdering = enum(u8) {
    relaxed,
    acquire,
    release,
    acq_rel,
    seq_cst,
};

pub const AtomicRmwOp = enum(u8) {
    add,
    sub,
    @"and",
    @"or",
    xor,
    xchg,
    min,
    max,
    umin,
    umax,
};

pub const ParseError = error{
    InvalidAtomicSyntax,
    InvalidAtomicOrdering,
    UnsupportedType,
};

fn isAtomicValueType(ty: sig.PrimType) bool {
    return switch (ty) {
        .i1, .i8, .i16, .i32, .i64, .u8, .u16, .u32, .u64, .ptr => true,
        else => false,
    };
}

pub fn orderingName(ordering: AtomicOrdering) []const u8 {
    return switch (ordering) {
        .relaxed => "relaxed",
        .acquire => "acquire",
        .release => "release",
        .acq_rel => "acq_rel",
        .seq_cst => "seq_cst",
    };
}

pub fn llvmOrderingName(ordering: AtomicOrdering) []const u8 {
    return switch (ordering) {
        .relaxed => "monotonic",
        .acquire => "acquire",
        .release => "release",
        .acq_rel => "acq_rel",
        .seq_cst => "seq_cst",
    };
}

pub fn orderingStrength(ordering: AtomicOrdering) u8 {
    return switch (ordering) {
        .relaxed => 0,
        .acquire => 1,
        .release => 1,
        .acq_rel => 2,
        .seq_cst => 3,
    };
}

pub fn parseOrdering(text: []const u8) ?AtomicOrdering {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    inline for ([_]struct { name: []const u8, ordering: AtomicOrdering }{
        .{ .name = "relaxed", .ordering = .relaxed },
        .{ .name = "acquire", .ordering = .acquire },
        .{ .name = "release", .ordering = .release },
        .{ .name = "acq_rel", .ordering = .acq_rel },
        .{ .name = "seq_cst", .ordering = .seq_cst },
    }) |item| {
        if (std.mem.eql(u8, trimmed, item.name)) return item.ordering;
    }
    return null;
}

pub fn cmpxchgFailureAllowed(success: AtomicOrdering, failure: AtomicOrdering) bool {
    return switch (success) {
        .relaxed => failure == .relaxed,
        .acquire => failure == .relaxed or failure == .acquire,
        .release => failure == .relaxed,
        .acq_rel => failure == .relaxed or failure == .acquire,
        .seq_cst => failure == .relaxed or failure == .acquire or failure == .seq_cst,
    };
}

pub fn sameAddressRmwCompatible(prev: AtomicOrdering, next: AtomicOrdering) bool {
    if (prev == next) return true;
    if (prev == .seq_cst or next == .seq_cst) return true;
    return false;
}

pub fn parseRmwOp(text: []const u8) ?AtomicRmwOp {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    inline for ([_]struct { name: []const u8, op: AtomicRmwOp }{
        .{ .name = "add", .op = .add },
        .{ .name = "sub", .op = .sub },
        .{ .name = "and", .op = .@"and" },
        .{ .name = "or", .op = .@"or" },
        .{ .name = "xor", .op = .xor },
        .{ .name = "xchg", .op = .xchg },
        .{ .name = "min", .op = .min },
        .{ .name = "max", .op = .max },
        .{ .name = "smin", .op = .min },
        .{ .name = "smax", .op = .max },
        .{ .name = "umin", .op = .umin },
        .{ .name = "umax", .op = .umax },
    }) |item| {
        if (std.mem.eql(u8, trimmed, item.name)) return item.op;
    }
    return null;
}

pub fn rmwOpName(op: AtomicRmwOp) []const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .@"and" => "and",
        .@"or" => "or",
        .xor => "xor",
        .xchg => "xchg",
        .min => "min",
        .max => "max",
        .umin => "umin",
        .umax => "umax",
    };
}

fn startsWithWord(s: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, s, word)) return false;
    if (s.len == word.len) return true;
    const next = s[word.len];
    return std.ascii.isWhitespace(next) or next == '(' or next == '[' or next == ':' or next == '=' or next == '@' or next == '-';
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

fn splitCommaPair(text: []const u8) ?struct { left: []const u8, right: []const u8 } {
    const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const left = std.mem.trim(u8, text[0..comma], " \t");
    const right = std.mem.trim(u8, text[comma + 1 ..], " \t");
    if (left.len == 0 or right.len == 0) return null;
    return .{ .left = left, .right = right };
}

fn splitCommaTriple(text: []const u8) ?struct { first: []const u8, second: []const u8, third: []const u8 } {
    const first_comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
    const second_segment = std.mem.trimLeft(u8, text[first_comma + 1 ..], " \t");
    const second_comma = std.mem.indexOfScalar(u8, second_segment, ',') orelse return null;
    const first = std.mem.trim(u8, text[0..first_comma], " \t");
    const second = std.mem.trim(u8, second_segment[0..second_comma], " \t");
    const third = std.mem.trim(u8, second_segment[second_comma + 1 ..], " \t");
    if (first.len == 0 or second.len == 0 or third.len == 0) return null;
    return .{ .first = first, .second = second, .third = third };
}

fn parseAddress(text: []const u8) ?struct { base: []const u8, offset: []const u8 } {
    const plus = std.mem.indexOfScalar(u8, text, '+') orelse return null;
    const base = std.mem.trim(u8, text[0..plus], " \t");
    const offset = std.mem.trim(u8, text[plus + 1 ..], " \t");
    if (base.len == 0 or offset.len == 0) return null;
    return .{ .base = base, .offset = offset };
}

fn splitTrailingType(text: []const u8) ?struct { body: []const u8, ty: []const u8 } {
    const trimmed = std.mem.trim(u8, text, " \t");
    const idx = std.mem.lastIndexOf(u8, trimmed, " as ") orelse return null;
    const body = std.mem.trimRight(u8, trimmed[0..idx], " \t");
    const ty = std.mem.trim(u8, trimmed[idx + 4 ..], " \t");
    if (body.len == 0 or ty.len == 0) return null;
    return .{ .body = body, .ty = ty };
}

fn peelLastToken(text: []const u8) ?struct { body: []const u8, token: []const u8 } {
    var end: usize = text.len;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) : (end -= 1) {}
    if (end == 0) return null;
    var start: usize = end;
    while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) : (start -= 1) {}
    return .{
        .body = std.mem.trimRight(u8, text[0..start], " \t"),
        .token = text[start..end],
    };
}

fn stripOrderingSuffix(text: []const u8) struct { body: []const u8, ordering: ?AtomicOrdering } {
    if (peelLastToken(text)) |peel| {
        if (parseOrdering(peel.token)) |ordering| {
            return .{ .body = peel.body, .ordering = ordering };
        }
    }
    return .{ .body = std.mem.trimRight(u8, text, " \t"), .ordering = null };
}

fn stripCmpxchgOrderingSuffix(text: []const u8) struct { body: []const u8, success: AtomicOrdering, failure: AtomicOrdering } {
    const first = stripOrderingSuffix(text);
    if (first.ordering) |failure| {
        if (peelLastToken(first.body)) |peel| {
            if (parseOrdering(peel.token)) |success| {
                return .{ .body = peel.body, .success = success, .failure = failure };
            }
        }
        return .{ .body = first.body, .success = failure, .failure = .acquire };
    }
    return .{ .body = std.mem.trimRight(u8, text, " \t"), .success = .seq_cst, .failure = .acquire };
}

pub const Load = struct {
    dst: []const u8,
    base: []const u8,
    offset: []const u8,
    ty: ?sig.PrimType,
    ordering: AtomicOrdering,
};

pub const Store = struct {
    base: []const u8,
    offset: []const u8,
    value: []const u8,
    ty: ?sig.PrimType,
    ordering: AtomicOrdering,
};

pub const Cmpxchg = struct {
    dst: []const u8,
    ok: []const u8,
    base: []const u8,
    offset: []const u8,
    expected: []const u8,
    new_value: []const u8,
    ty: ?sig.PrimType,
    success_ordering: AtomicOrdering,
    failure_ordering: AtomicOrdering,
};

pub const Rmw = struct {
    dst: []const u8,
    op: AtomicRmwOp,
    base: []const u8,
    offset: []const u8,
    value: []const u8,
    ty: ?sig.PrimType,
    ordering: AtomicOrdering,
};

pub const Fence = struct {
    ordering: AtomicOrdering,
};

pub fn parseLoad(text: []const u8) ParseError!Load {
    const assignment = splitAssignment(text) orelse return ParseError.InvalidAtomicSyntax;
    const dst = std.mem.trim(u8, assignment.lhs, " \t");
    const rhs = std.mem.trim(u8, assignment.rhs, " \t");
    if (dst.len == 0 or !startsWithWord(rhs, "atomic_load")) return ParseError.InvalidAtomicSyntax;
    var body = std.mem.trimLeft(u8, rhs["atomic_load".len..], " \t");
    if (body.len == 0) return ParseError.InvalidAtomicSyntax;
    const order = stripOrderingSuffix(body);
    body = order.body;
    var ty: ?sig.PrimType = null;
    if (splitTrailingType(body)) |suffix| {
        body = suffix.body;
        ty = sig.parsePrimType(suffix.ty) catch return ParseError.UnsupportedType;
        if (!isAtomicValueType(ty.?)) return ParseError.UnsupportedType;
    }
    const addr = parseAddress(body) orelse return ParseError.InvalidAtomicSyntax;
    return .{
        .dst = dst,
        .base = addr.base,
        .offset = addr.offset,
        .ty = ty,
        .ordering = order.ordering orelse .seq_cst,
    };
}

pub fn parseStore(text: []const u8) ParseError!Store {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (!startsWithWord(trimmed, "atomic_store")) return ParseError.InvalidAtomicSyntax;
    var body = std.mem.trimLeft(u8, trimmed["atomic_store".len..], " \t");
    if (body.len == 0) return ParseError.InvalidAtomicSyntax;
    const order = stripOrderingSuffix(body);
    body = order.body;
    var ty: ?sig.PrimType = null;
    if (splitTrailingType(body)) |suffix| {
        body = suffix.body;
        ty = sig.parsePrimType(suffix.ty) catch return ParseError.UnsupportedType;
        if (!isAtomicValueType(ty.?)) return ParseError.UnsupportedType;
    }
    const pair = splitCommaPair(body) orelse return ParseError.InvalidAtomicSyntax;
    const addr = parseAddress(pair.left) orelse return ParseError.InvalidAtomicSyntax;
    return .{
        .base = addr.base,
        .offset = addr.offset,
        .value = pair.right,
        .ty = ty,
        .ordering = order.ordering orelse .seq_cst,
    };
}

pub fn parseCmpxchg(text: []const u8) ParseError!Cmpxchg {
    const assignment = splitAssignment(text) orelse return ParseError.InvalidAtomicSyntax;
    const lhs_pair = splitCommaPair(assignment.lhs) orelse return ParseError.InvalidAtomicSyntax;
    const lhs_old = lhs_pair.left;
    const lhs_ok = lhs_pair.right;
    const rhs = std.mem.trim(u8, assignment.rhs, " \t");
    if (lhs_old.len == 0 or lhs_ok.len == 0 or !startsWithWord(rhs, "cmpxchg")) return ParseError.InvalidAtomicSyntax;
    var body = std.mem.trimLeft(u8, rhs["cmpxchg".len..], " \t");
    if (body.len == 0) return ParseError.InvalidAtomicSyntax;
    const order = stripCmpxchgOrderingSuffix(body);
    body = order.body;
    var ty: ?sig.PrimType = null;
    if (splitTrailingType(body)) |suffix| {
        body = suffix.body;
        ty = sig.parsePrimType(suffix.ty) catch return ParseError.UnsupportedType;
        if (!isAtomicValueType(ty.?)) return ParseError.UnsupportedType;
    }
    const triple = splitCommaTriple(body) orelse return ParseError.InvalidAtomicSyntax;
    const addr = parseAddress(triple.first) orelse return ParseError.InvalidAtomicSyntax;
    if (!cmpxchgFailureAllowed(order.success, order.failure)) return ParseError.InvalidAtomicOrdering;
    return .{
        .dst = lhs_old,
        .ok = lhs_ok,
        .base = addr.base,
        .offset = addr.offset,
        .expected = triple.second,
        .new_value = triple.third,
        .ty = ty,
        .success_ordering = order.success,
        .failure_ordering = order.failure,
    };
}

pub fn parseRmw(text: []const u8) ParseError!Rmw {
    const assignment = splitAssignment(text) orelse return ParseError.InvalidAtomicSyntax;
    const dst = std.mem.trim(u8, assignment.lhs, " \t");
    const rhs = std.mem.trim(u8, assignment.rhs, " \t");
    if (dst.len == 0 or !std.mem.startsWith(u8, rhs, "atomic_rmw_")) return ParseError.InvalidAtomicSyntax;
    const suffix = std.mem.trimLeft(u8, rhs["atomic_rmw_".len..], " \t");
    const op_end = std.mem.indexOfAny(u8, suffix, " \t(") orelse suffix.len;
    const op_text = suffix[0..op_end];
    const op = parseRmwOp(op_text) orelse return ParseError.InvalidAtomicSyntax;
    var body = std.mem.trimLeft(u8, suffix[op_end..], " \t");
    if (body.len == 0) return ParseError.InvalidAtomicSyntax;
    const order = stripOrderingSuffix(body);
    body = order.body;
    var ty: ?sig.PrimType = null;
    if (splitTrailingType(body)) |suffix_ty| {
        body = suffix_ty.body;
        ty = sig.parsePrimType(suffix_ty.ty) catch return ParseError.UnsupportedType;
        if (!isAtomicValueType(ty.?)) return ParseError.UnsupportedType;
    }
    const pair = splitCommaPair(body) orelse return ParseError.InvalidAtomicSyntax;
    const addr = parseAddress(pair.left) orelse return ParseError.InvalidAtomicSyntax;
    return .{
        .dst = dst,
        .op = op,
        .base = addr.base,
        .offset = addr.offset,
        .value = pair.right,
        .ty = ty,
        .ordering = order.ordering orelse .seq_cst,
    };
}

pub fn parseFence(text: []const u8) ParseError!Fence {
    const trimmed = std.mem.trim(u8, text, " \t\r");
    if (!startsWithWord(trimmed, "fence")) return ParseError.InvalidAtomicSyntax;
    const body = std.mem.trimLeft(u8, trimmed["fence".len..], " \t");
    if (body.len == 0) return .{ .ordering = .seq_cst };
    const order = stripOrderingSuffix(body);
    if (std.mem.trim(u8, order.body, " \t").len != 0) return ParseError.InvalidAtomicSyntax;
    return .{ .ordering = order.ordering orelse .seq_cst };
}

test "atomic ordering helpers" {
    try std.testing.expectEqualStrings("monotonic", llvmOrderingName(.relaxed));
    try std.testing.expectEqualStrings("seq_cst", llvmOrderingName(.seq_cst));
    try std.testing.expect(cmpxchgFailureAllowed(.seq_cst, .acquire));
    try std.testing.expect(!cmpxchgFailureAllowed(.release, .acquire));
    try std.testing.expect(sameAddressRmwCompatible(.seq_cst, .relaxed));
    try std.testing.expect(!sameAddressRmwCompatible(.release, .acquire));
}
