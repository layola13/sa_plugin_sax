const std = @import("std");

const def_dict = @import("flattener/def_dict.zig");
const classifier = @import("flattener/line_classifier.zig");
const forbidden = @import("flattener/forbidden.zig");
const symbol = @import("flattener/symbol.zig");
const common_instruction = @import("common/instruction.zig");
const common_const_decl = @import("common/const_decl.zig");
const atomic = @import("common/atomic.zig");
const common_signature = @import("common/signature.zig");
const common_trap = @import("common/trap.zig");
const common_upstream = @import("common/upstream_loc.zig");
const pkg_resolver = @import("pkg/resolver.zig");

pub const LineKind = classifier.LineKind;
pub const InstructionForm = classifier.InstructionForm;
pub const ClassifiedLine = classifier.ClassifiedLine;
pub const ForbiddenHit = forbidden.ForbiddenHit;
pub const DefDict = def_dict.DefDict;
pub const DefError = def_dict.DefError;
pub const SymbolTable = symbol.SymbolTable;
pub const Instruction = common_instruction.Instruction;
pub const InstKind = common_instruction.InstKind;
pub const Operand = common_instruction.Operand;
pub const ConstDecl = common_const_decl.ConstDecl;
pub const FunctionSig = common_signature.FunctionSig;
pub const FunctionKind = common_signature.FunctionKind;
pub const Trap = common_trap.Trap;
pub const LocTable = common_upstream.LocTable;

pub const ResolveContext = struct {
    dependencies: []const pkg_resolver.Dependency = &.{},
    options: pkg_resolver.ResolveOptions = .{},
    package_identity: ?[]const u8 = null,
};

pub const LayoutVersion = struct {
    path: []u8,
    version: u64,

    fn deinit(self: *LayoutVersion, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

const MacroDef = struct {
    params: []const []const u8,
    variadic_param: ?[]const u8 = null,
    body_start: usize,
    body_end: usize,

    fn deinit(self: *MacroDef, allocator: std.mem.Allocator) void {
        allocator.free(self.params);
        self.* = undefined;
    }
};

const Replacement = struct {
    needle: []const u8,
    replacement: []const u8,
};

pub const SourceLine = struct {
    line_no: u32,
    text: []const u8,
    classified: ClassifiedLine,
    package_identity: ?[]const u8 = null,
    package_source_sha256: ?[32]u8 = null,
};

pub const ErrorContext = struct {
    source_line: ?u32 = null,
};

fn recordErrorSourceLine(error_ctx: ?*ErrorContext, line_no: u32) void {
    if (error_ctx) |ctx| {
        ctx.source_line = line_no;
    }
}

pub fn takeErrorSourceLine(error_ctx: *ErrorContext) ?u32 {
    const line_no = error_ctx.source_line;
    error_ctx.source_line = null;
    return line_no;
}

fn appendExpandedLine(
    out: *std.ArrayList(u8),
    line_package_identities: *std.ArrayList(?[]const u8),
    line_package_hashes: *std.ArrayList(?[32]u8),
    text: []const u8,
    package_identity: ?[]const u8,
    package_hash: ?[32]u8,
) !void {
    try out.appendSlice(text);
    try out.append('\n');
    try line_package_identities.append(package_identity);
    try line_package_hashes.append(package_hash);
}

const ImportExpansion = struct {
    source: []u8,
    active_paths: std.StringHashMap(void),
    seen_paths: std.StringHashMap(void),
    seen_package_identities: std.StringHashMap(void),
    line_package_identities: std.ArrayList(?[]const u8),
    line_package_hashes: std.ArrayList(?[32]u8),
    owned_paths: std.ArrayList([]u8),
    layout_versions: std.ArrayList(LayoutVersion),

    pub fn deinit(self: *ImportExpansion, allocator: std.mem.Allocator) void {
        self.line_package_identities.deinit();
        self.line_package_hashes.deinit();
        for (self.owned_paths.items) |path| {
            allocator.free(path);
        }
        self.owned_paths.deinit();
        var pkg_it = self.seen_package_identities.iterator();
        while (pkg_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.seen_package_identities.deinit();
        for (self.layout_versions.items) |*layout_version| layout_version.deinit(allocator);
        self.layout_versions.deinit();
        self.active_paths.deinit();
        self.seen_paths.deinit();
        allocator.free(self.source);
        self.* = undefined;
    }
};

pub const FlattenResult = struct {
    instructions: []Instruction,
    const_decls: []ConstDecl,
    function_sigs: []FunctionSig,
    test_sigs: []FunctionSig,
    def_dict: DefDict,
    symbols: SymbolTable,
    loc_table: LocTable,
    layout_versions: []LayoutVersion,
    package_identities: std.StringHashMap(void),
    owned_text: [][]const u8,
    trap: ?Trap = null,

    pub fn deinit(self: *FlattenResult, allocator: std.mem.Allocator) void {
        for (self.loc_table) |entry| {
            if (entry) |loc| allocator.free(loc.file);
        }
        allocator.free(self.loc_table);
        for (self.layout_versions) |*layout_version| layout_version.deinit(allocator);
        allocator.free(self.layout_versions);
        var pkg_it = self.package_identities.iterator();
        while (pkg_it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.package_identities.deinit();
        for (self.instructions) |item| {
            if (item.package_identity) |identity| allocator.free(identity);
            if (item.upstream_loc) |loc| allocator.free(loc.file);
            if (item.native_reg_names.len != 0) allocator.free(item.native_reg_names);
        }
        for (self.const_decls) |*decl| decl.deinit(allocator);
        allocator.free(self.const_decls);
        for (self.owned_text) |text| allocator.free(text);
        allocator.free(self.owned_text);
        for (self.function_sigs) |*sig| sig.deinit(allocator);
        allocator.free(self.function_sigs);
        allocator.free(self.test_sigs);
        allocator.free(self.instructions);
        self.def_dict.deinit();
        self.symbols.deinit();
        self.* = undefined;
    }
};

pub const ForbiddenLine = struct {
    line_no: u32,
    hit: ForbiddenHit,
};

fn parseTokenList(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) {
        return try allocator.alloc([]const u8, 0);
    }

    var list = std.ArrayList([]const u8).init(allocator);
    errdefer list.deinit();

    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |item| {
        const token = std.mem.trim(u8, item, " \t");
        if (token.len == 0) return error.InvalidMacroInvocation;
        try list.append(token);
    }

    return try list.toOwnedSlice();
}

fn parseMacroParams(allocator: std.mem.Allocator, text: []const u8) !struct { params: []const []const u8, variadic_param: ?[]const u8 } {
    const raw_params = try parseTokenList(allocator, text);
    errdefer allocator.free(raw_params);

    var variadic_param: ?[]const u8 = null;
    var param_count = raw_params.len;

    for (raw_params, 0..) |param, idx| {
        if (std.mem.endsWith(u8, param, "...")) {
            if (idx + 1 != raw_params.len) return error.InvalidMacroInvocation;
            const base = std.mem.trimRight(u8, param[0 .. param.len - 3], " \t");
            if (base.len == 0) return error.InvalidMacroInvocation;
            variadic_param = base;
            param_count = idx;
        }
    }

    if (param_count == raw_params.len) {
        return .{ .params = raw_params, .variadic_param = null };
    }

    const fixed_params = try allocator.alloc([]const u8, param_count);
    errdefer allocator.free(fixed_params);
    @memcpy(fixed_params, raw_params[0..param_count]);
    allocator.free(raw_params);
    return .{ .params = fixed_params, .variadic_param = variadic_param };
}

fn joinTokens(allocator: std.mem.Allocator, tokens: []const []const u8) ![]const u8 {
    if (tokens.len == 0) return try allocator.dupe(u8, "");
    var total_len: usize = 0;
    for (tokens) |token| total_len += token.len;
    total_len += (tokens.len - 1) * 2;

    var out = try allocator.alloc(u8, total_len);
    var cursor: usize = 0;
    for (tokens, 0..) |token, idx| {
        if (idx != 0) {
            out[cursor] = ',';
            out[cursor + 1] = ' ';
            cursor += 2;
        }
        @memcpy(out[cursor .. cursor + token.len], token);
        cursor += token.len;
    }
    return out;
}

fn deinitMacroMap(allocator: std.mem.Allocator, macros: *std.StringHashMap(MacroDef)) void {
    var it = macros.valueIterator();
    while (it.next()) |macro_def| {
        allocator.free(macro_def.params);
    }
    macros.deinit();
}

fn renderWithReplacements(
    allocator: std.mem.Allocator,
    text: []const u8,
    replacements: []const Replacement,
) ![]const u8 {
    if (replacements.len == 0) {
        return try allocator.dupe(u8, text);
    }

    var current = try allocator.dupe(u8, text);
    errdefer allocator.free(current);

    for (replacements) |replacement| {
        if (replacement.needle.len == 0) continue;
        const next = try std.mem.replaceOwned(u8, allocator, current, replacement.needle, replacement.replacement);
        allocator.free(current);
        current = next;
    }

    return current;
}

fn ownText(
    allocator: std.mem.Allocator,
    owned_text: *std.ArrayList([]const u8),
    text: []const u8,
) ![]const u8 {
    const dup = try allocator.dupe(u8, text);
    errdefer allocator.free(dup);
    try owned_text.append(dup);
    return dup;
}

fn ownFoldedText(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    owned_text: *std.ArrayList([]const u8),
    text: []const u8,
) ![]const u8 {
    const folded = try dict.foldText(allocator, text);
    errdefer allocator.free(folded);
    try owned_text.append(folded);
    return folded;
}

fn stripLeadingPlus(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len > 0 and trimmed[0] == '+') {
        return std.mem.trimLeft(u8, trimmed[1..], " \t");
    }
    return trimmed;
}

fn parseIntAllowLeadingPlus(comptime T: type, text: []const u8) !T {
    const normalized = stripLeadingPlus(text);
    return std.fmt.parseInt(T, normalized, 10) catch |err| {
        return err;
    };
}

fn parseLayoutOffset(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    owned_text: *std.ArrayList([]const u8),
    current_package_identity: ?[]const u8,
    text: []const u8,
) !u64 {
    const folded = try ownFoldedText(allocator, dict, owned_text, text);
    if (parseIntAllowLeadingPlus(u64, folded)) |value| {
        return value;
    } else |err| switch (err) {
        error.InvalidCharacter => {},
        else => return err,
    }

    if (dict.get(folded)) |value_text| {
        return try parseIntAllowLeadingPlus(u64, value_text);
    }

    if (current_package_identity) |identity| {
        const prefix = try packageNamespacePrefix(allocator, identity);
        defer allocator.free(prefix);

        const qualified = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, folded });
        defer allocator.free(qualified);

        if (dict.get(qualified)) |value_text| {
            return try parseIntAllowLeadingPlus(u64, value_text);
        }
    }

    var it = dict.entries.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.endsWith(u8, key, folded) and key.len > folded.len) {
            const separator = key[key.len - folded.len - 1];
            if (separator != '.' and separator != '_') continue;
            return try parseIntAllowLeadingPlus(u64, entry.value_ptr.*);
        }
    }

    std.debug.print("\nparseLayoutOffset failed for folded: '{s}' (text: '{s}')\nAvailable keys in dict:\n", .{ folded, text });
    var it_keys = dict.entries.iterator();
    while (it_keys.next()) |entry| {
        std.debug.print("  - '{s}': '{s}'\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return error.InvalidSyntax;
}

fn parseNumericOperand(text: []const u8) ?common_instruction.Operand {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;

    if (std.fmt.parseInt(i64, trimmed, 10)) |value| {
        return .{ .imm_i64 = value };
    } else |err| switch (err) {
        error.Overflow => {
            if (std.fmt.parseInt(u64, trimmed, 10)) |value| {
                return .{ .imm_u64 = value };
            } else |_| {}
        },
        error.InvalidCharacter => {
            const no_plus = stripLeadingPlus(trimmed);
            if (no_plus.len != trimmed.len) {
                if (std.fmt.parseInt(i64, no_plus, 10)) |value| {
                    return .{ .imm_i64 = value };
                } else |retry_err| switch (retry_err) {
                    error.Overflow => {
                        if (std.fmt.parseInt(u64, no_plus, 10)) |value| {
                            return .{ .imm_u64 = value };
                        } else |_| {}
                    },
                    else => {},
                }
            }
        },
    }

    if (std.mem.indexOfAny(u8, trimmed, ".eE")) |_| {
        if (std.fmt.parseFloat(f64, trimmed)) |value| {
            return .{ .imm_float = value };
        } else |_| {}
    }

    return null;
}

fn parseSizeOperand(text: []const u8) ?common_instruction.Operand {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;

    if (std.fmt.parseInt(i64, trimmed, 10)) |value| {
        if (value >= 0) {
            return .{ .imm_u64 = @as(u64, @intCast(value)) };
        }
        return .{ .imm_i64 = value };
    } else |err| switch (err) {
        error.Overflow => {
            if (std.fmt.parseInt(u64, trimmed, 10)) |value| {
                return .{ .imm_u64 = value };
            } else |_| {}
        },
        error.InvalidCharacter => {
            const no_plus = stripLeadingPlus(trimmed);
            if (no_plus.len != trimmed.len) {
                if (std.fmt.parseInt(i64, no_plus, 10)) |value| {
                    if (value >= 0) {
                        return .{ .imm_u64 = @as(u64, @intCast(value)) };
                    }
                    return .{ .imm_i64 = value };
                } else |retry_err| switch (retry_err) {
                    error.Overflow => {
                        if (std.fmt.parseInt(u64, no_plus, 10)) |value| {
                            return .{ .imm_u64 = value };
                        } else |_| {}
                    },
                    else => {},
                }
            }
        },
    }

    return null;
}

fn resolveOperandText(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    owned_text: *std.ArrayList([]const u8),
    symbols: *SymbolTable,
    text: []const u8,
) !common_instruction.Operand {
    const folded = try ownFoldedText(allocator, dict, owned_text, text);
    if (parseNumericOperand(folded)) |operand| return operand;
    return .{ .reg = try symbols.intern(folded) };
}

fn resolveSizeOperandText(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    owned_text: *std.ArrayList([]const u8),
    symbols: *SymbolTable,
    text: []const u8,
) !common_instruction.Operand {
    const folded = try ownFoldedText(allocator, dict, owned_text, text);
    if (parseSizeOperand(folded)) |operand| return operand;
    if (symbols.findId(folded)) |id| {
        return .{ .reg = id };
    }
    return .{ .reg = try symbols.intern(folded) };
}

fn consumePendingLoc(
    loc_table: *std.ArrayList(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
) !?common_upstream.UpstreamLoc {
    const loc = pending_loc.*;
    try loc_table.append(loc);
    pending_loc.* = null;
    return loc;
}

fn takePendingLoc(
    pending_loc: *?common_upstream.UpstreamLoc,
) ?common_upstream.UpstreamLoc {
    const loc = pending_loc.*;
    pending_loc.* = null;
    return loc;
}

fn appendNullLoc(loc_table: *std.ArrayList(?common_upstream.UpstreamLoc)) !void {
    try loc_table.append(null);
}

fn setPendingLoc(
    allocator: std.mem.Allocator,
    pending_loc: *?common_upstream.UpstreamLoc,
    file: []const u8,
    line: u32,
    col: u32,
) !void {
    if (pending_loc.*) |current| {
        allocator.free(current.file);
        pending_loc.* = null;
    }
    const file_copy = try allocator.dupe(u8, file);
    pending_loc.* = .{
        .file = file_copy,
        .line = line,
        .col = col,
    };
}

fn recordLayoutVersion(
    allocator: std.mem.Allocator,
    layout_versions: *std.ArrayList(LayoutVersion),
    path: []const u8,
    source: []const u8,
) !void {
    var iterator = std.mem.splitScalar(u8, source, '\n');
    while (iterator.next()) |raw_line| {
        const classified = classifier.classifyLine(raw_line);
        if (classified.kind != .version) continue;

        const version = std.fmt.parseInt(u64, classified.parts[0], 10) catch return error.InvalidSyntax;
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);
        try layout_versions.append(.{
            .path = path_copy,
            .version = version,
        });
        return;
    }
}

fn findBlockEnd(lines: []const SourceLine, start: usize, close_kind: LineKind) ?usize {
    var idx = start;
    while (idx < lines.len) : (idx += 1) {
        if (lines[idx].classified.kind == close_kind) return idx;
    }
    return null;
}

fn findNestedRepEnd(lines: []const SourceLine, start: usize) ?usize {
    var depth: usize = 1;
    var idx = start;
    while (idx < lines.len) : (idx += 1) {
        switch (lines[idx].classified.kind) {
            .rep_start => depth += 1,
            .rep_end => {
                depth -= 1;
                if (depth == 0) return idx;
            },
            else => {},
        }
    }
    return null;
}

const IfBounds = struct {
    else_idx: ?usize,
    end_idx: usize,
};

fn findNestedIfBounds(lines: []const SourceLine, start: usize) ?IfBounds {
    var depth: usize = 1;
    var else_idx: ?usize = null;
    var idx = start;
    while (idx < lines.len) : (idx += 1) {
        switch (lines[idx].classified.kind) {
            .if_start => depth += 1,
            .else_ => {
                if (depth == 1 and else_idx == null) else_idx = idx;
            },
            .if_end => {
                depth -= 1;
                if (depth == 0) return .{ .else_idx = else_idx, .end_idx = idx };
            },
            else => {},
        }
    }
    return null;
}

fn macroConditionIsTrue(text: []const u8) !bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "yes") or std.mem.eql(u8, trimmed, "on")) return true;
    if (std.mem.eql(u8, trimmed, "0") or std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "no") or std.mem.eql(u8, trimmed, "off")) return false;
    return error.InvalidMacroInvocation;
}

fn mapInstKind(form: InstructionForm) InstKind {
    return switch (form) {
        .alloc => .alloc,
        .stack_alloc => .stack_alloc,
        .load => .load,
        .store => .store,
        .atomic_load => .atomic_load,
        .atomic_store => .atomic_store,
        .cmpxchg => .cmpxchg,
        .atomic_rmw => .atomic_rmw,
        .fence => .fence,
        .borrow => .borrow,
        .move_ => .move_,
        .release => .release,
        .assign => .assign,
        .op => .op,
        .ptr_add => .ptr_add,
        .jmp => .jmp,
        .br => .br,
        .br_null => .br_null,
        .call => .call,
        .call_indirect => .call_indirect,
        .try_ => .early_return,
        .panic => .panic,
        .panic_msg => .panic_msg,
        .return_ => .return_,
        .take => .take,
        .raw_cast => .raw_cast,
        .assume_safe => .assume_safe,
        .assume_borrow => .assume_borrow,
        .unknown => .native,
    };
}

fn parseFunctionSigForKind(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
    id: u32,
    entry_idx: u32,
    kind: FunctionKind,
    symbols: *SymbolTable,
) !FunctionSig {
    var sig = try common_signature.parseFunctionHeader(allocator, raw_line, id, entry_idx, kind);
    errdefer sig.deinit(allocator);
    if (sig.params.len == 0) {
        sig.param_ids = &.{};
        return sig;
    }
    const ids = try allocator.alloc(u32, sig.params.len);
    errdefer allocator.free(ids);
    for (sig.params, 0..) |param, idx| {
        ids[idx] = try symbols.intern(param.name);
    }
    sig.param_ids = ids;
    return sig;
}

fn emitParsedLine(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.ArrayList(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    raw_line: []const u8,
    source_line: u32,
    instructions: *std.ArrayList(Instruction),
    const_decls: *std.ArrayList(ConstDecl),
    function_sigs: *std.ArrayList(FunctionSig),
    owned_text: *std.ArrayList([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    const classified = classifier.classifyLine(raw_line);
    switch (classified.kind) {
        .blank_or_comment, .version => {},
        .import_decl => {},
        .const_decl => {
            const upstream_loc = takePendingLoc(pending_loc);
            errdefer if (upstream_loc) |loc| allocator.free(loc.file);
            var decl = try common_const_decl.parseConstDecl(
                allocator,
                raw_line,
                source_line,
                @intCast(instructions.items.len),
                upstream_loc,
            );
            errdefer decl.deinit(allocator);
            _ = try symbols.intern(decl.name);
            try const_decls.append(decl);
        },
        .loc_hint => {
            const line_no = try std.fmt.parseInt(u32, classified.parts[1], 10);
            const col_no = try std.fmt.parseInt(u32, classified.parts[2], 10);
            try setPendingLoc(allocator, pending_loc, classified.parts[0], line_no, col_no);
        },
        .def => try dict.putExpression(classified.parts[0], classified.parts[1]),
        .native => {
            const inst_loc = try consumePendingLoc(loc_table, pending_loc);
            const raw_copy = try ownText(allocator, owned_text, raw_line);
            const native_copy = try ownText(allocator, owned_text, classified.parts[0]);
            const native_reg_names = try classifier.collectNativeRegisterNames(allocator, native_copy);
            var inst = common_instruction.makeInstruction(.native, source_line, @intCast(instructions.items.len), inst_loc, raw_copy);
            inst.operands[0] = .{ .native_text = native_copy };
            inst.native_reg_names = native_reg_names;
            try instructions.append(inst);
        },
        .label => {
            const label_name = try ownFoldedText(allocator, dict, owned_text, classified.parts[0]);
            try appendNullLoc(loc_table);
            const label_id = try symbols.intern(label_name);
            const raw_copy = try ownText(allocator, owned_text, raw_line);
            var inst = common_instruction.makeInstruction(.label, source_line, @intCast(instructions.items.len), null, raw_copy);
            inst.operands[0] = .{ .symbol = label_id };
            inst.operands[1] = .{ .label = label_id };
            try instructions.append(inst);
        },
        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
            const kind = switch (classified.kind) {
                .func_decl => FunctionKind.normal,
                .ffi_wrapper_decl => FunctionKind.ffi_wrapper,
                .extern_decl => FunctionKind.external,
                .export_decl => FunctionKind.exported,
                .test_decl => FunctionKind.test_func,
                else => FunctionKind.normal,
            };
            var sig = try parseFunctionSigForKind(
                allocator,
                raw_line,
                @intCast(function_sigs.items.len),
                @intCast(instructions.items.len),
                kind,
                symbols,
            );
            errdefer sig.deinit(allocator);
            var inst_loc: ?common_upstream.UpstreamLoc = null;
            if (pending_loc.*) |loc| {
                const sig_file_copy = try allocator.dupe(u8, loc.file);
                errdefer allocator.free(sig_file_copy);
                const inst_file_copy = try allocator.dupe(u8, loc.file);
                errdefer allocator.free(inst_file_copy);
                sig.upstream_file = sig_file_copy;
                sig.upstream_loc = .{
                    .file = sig_file_copy,
                    .line = loc.line,
                    .col = loc.col,
                };
                inst_loc = .{
                    .file = inst_file_copy,
                    .line = loc.line,
                    .col = loc.col,
                };
            }
            const name_id = try symbols.intern(sig.name);
            const inst_kind: InstKind = switch (kind) {
                .normal => .func_decl,
                .ffi_wrapper => .ffi_wrapper_decl,
                .external => .extern_decl,
                .exported => .export_decl,
                .test_func => .test_decl,
            };
            try appendNullLoc(loc_table);
            const raw_copy = try ownFoldedText(allocator, dict, owned_text, raw_line);
            var inst = common_instruction.makeInstruction(inst_kind, source_line, @intCast(instructions.items.len), inst_loc, raw_copy);
            if (current_package_identity) |identity| {
                inst.package_identity = try allocator.dupe(u8, identity);
            }
            inst.package_source_sha256 = current_package_hash;
            inst.operands[0] = .{ .symbol = name_id };
            inst.operands[1] = .{ .func = name_id };
            try instructions.append(inst);
            try function_sigs.append(sig);
        },
        .instruction => {
            const inst_kind = mapInstKind(classified.inst_form.?);
            const inst_loc = try consumePendingLoc(loc_table, pending_loc);
            const raw_copy = try ownFoldedText(allocator, dict, owned_text, raw_line);
            var inst = common_instruction.makeInstruction(inst_kind, source_line, @intCast(instructions.items.len), inst_loc, raw_copy);
            if (current_package_identity) |identity| {
                inst.package_identity = try allocator.dupe(u8, identity);
            }
            inst.package_source_sha256 = current_package_hash;
            switch (classified.inst_form.?) {
                .alloc => {
                    const dst = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = try resolveSizeOperandText(allocator, dict, owned_text, symbols, classified.parts[1]);
                },
                .atomic_load => {
                    const parsed = atomic.parseLoad(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    const dst = try symbols.intern(parsed.dst);
                    const base = try symbols.intern(parsed.base);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, parsed.offset);
                    inst.operands[2] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    inst.atomic_value_ty = if (parsed.ty) |ty| @intFromEnum(ty) else null;
                    inst.atomic_ordering = parsed.ordering;
                },
                .atomic_store => {
                    const parsed = atomic.parseStore(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    const base = try symbols.intern(parsed.base);
                    inst.operands[0] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, parsed.offset);
                    inst.operands[1] = .{ .imm_u64 = try parseIntAllowLeadingPlus(u64, offset_text) };
                    const value_text = try ownFoldedText(allocator, dict, owned_text, parsed.value);
                    inst.operands[2] = .{ .text = value_text };
                    inst.atomic_value_ty = if (parsed.ty) |ty| @intFromEnum(ty) else null;
                    inst.atomic_ordering = parsed.ordering;
                },
                .cmpxchg => {
                    const parsed = atomic.parseCmpxchg(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    const dst = try symbols.intern(parsed.dst);
                    const ok = try symbols.intern(parsed.ok);
                    const base = try symbols.intern(parsed.base);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = ok };
                    inst.operands[2] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, parsed.offset);
                    inst.operands[3] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    inst.atomic_expected_text = try ownFoldedText(allocator, dict, owned_text, parsed.expected);
                    inst.atomic_new_text = try ownFoldedText(allocator, dict, owned_text, parsed.new_value);
                    inst.atomic_value_ty = if (parsed.ty) |ty| @intFromEnum(ty) else null;
                    inst.atomic_ordering = parsed.success_ordering;
                    inst.atomic_second_ordering = parsed.failure_ordering;
                },
                .atomic_rmw => {
                    const parsed = atomic.parseRmw(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    const dst = try symbols.intern(parsed.dst);
                    const base = try symbols.intern(parsed.base);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, parsed.offset);
                    inst.operands[2] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    const value_text = try ownFoldedText(allocator, dict, owned_text, parsed.value);
                    inst.operands[3] = .{ .text = value_text };
                    inst.atomic_value_ty = if (parsed.ty) |ty| @intFromEnum(ty) else null;
                    inst.atomic_ordering = parsed.ordering;
                    inst.atomic_rmw_op = parsed.op;
                },
                .fence => {
                    const parsed = atomic.parseFence(raw_line) catch |err| switch (err) {
                        error.InvalidAtomicOrdering => return error.InvalidAtomicOrdering,
                        error.UnsupportedType => return error.UnsupportedType,
                        else => return error.InvalidSyntax,
                    };
                    inst.atomic_ordering = parsed.ordering;
                },
                .stack_alloc => {
                    const dst = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = try resolveSizeOperandText(allocator, dict, owned_text, symbols, classified.parts[1]);
                },
                .load, .take => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const base = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, classified.parts[2]);
                    inst.operands[2] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    if (classified.part_count > 3) {
                        const ty = try common_signature.parsePrimType(classified.parts[3]);
                        inst.operands[3] = .{ .ty = @intFromEnum(ty) };
                    }
                },
                .borrow => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const source = try symbols.intern(classified.parts[2]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = source };
                    inst.operands[2] = .{ .text = classified.parts[1] };
                    inst.operands[3] = .{ .cap_prefix = .borrow };
                },
                .move_ => {
                    const reg = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = reg };
                },
                .release => {
                    const reg = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = reg };
                },
                .assign => {
                    const dst = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[1]);
                },
                .store => {
                    const base = try symbols.intern(classified.parts[0]);
                    inst.operands[0] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, classified.parts[1]);
                    inst.operands[1] = .{ .imm_u64 = try parseLayoutOffset(allocator, dict, owned_text, current_package_identity, offset_text) };
                    const value_text = try ownFoldedText(allocator, dict, owned_text, classified.parts[2]);
                    inst.operands[2] = .{ .text = value_text };
                    if (classified.part_count > 3) {
                        const ty = try common_signature.parsePrimType(classified.parts[3]);
                        inst.operands[3] = .{ .ty = @intFromEnum(ty) };
                    }
                },
                .op => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const op_name = classified.parts[1];
                    const op_kind = common_instruction.parseOpKind(op_name) orelse return error.InvalidSyntax;
                    inst.operands[0] = .{ .reg = dst };
                    inst.op_kind = op_kind;

                    if (common_instruction.isTernaryOpKind(op_kind)) {
                        inst.operands[1] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[2]);
                        inst.operands[2] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[3]);
                        inst.operands[3] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[4]);
                    } else if (common_instruction.isUnaryOpKind(op_kind)) {
                        inst.operands[1] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[2]);
                        if (common_instruction.isTypeConversionOpKind(op_kind)) {
                            const target_ty: common_signature.PrimType = if (classified.part_count > 3 and classified.parts[3].len != 0)
                                try common_signature.parsePrimType(classified.parts[3])
                            else
                                .i32;
                            inst.operands[2] = .{ .ty = @intFromEnum(target_ty) };
                        }
                    } else if (common_instruction.isBinaryOpKind(op_kind)) {
                        inst.operands[1] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[2]);
                        inst.operands[2] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[3]);
                        if (op_kind == .extract_lane and classified.part_count > 4) {
                            inst.operands[3] = try resolveOperandText(allocator, dict, owned_text, symbols, classified.parts[4]);
                        }
                    } else {
                        return error.InvalidSyntax;
                    }
                },
                .ptr_add => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const base = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = base };
                    const offset_text = try ownFoldedText(allocator, dict, owned_text, classified.parts[2]);
                    if (std.fmt.parseInt(i64, stripLeadingPlus(offset_text), 10)) |offset| {
                        inst.operands[2] = .{ .imm_i64 = offset };
                    } else |err| switch (err) {
                        error.Overflow => return error.InvalidSyntax,
                        else => {
                            if (symbols.findId(offset_text)) |off_reg| {
                                inst.operands[2] = .{ .reg = off_reg };
                            } else {
                                inst.operands[2] = .{ .text = offset_text };
                            }
                        },
                    }
                },
                .jmp => {
                    const target_text = try dict.foldText(allocator, classified.parts[0]);
                    try owned_text.append(target_text);
                    inst.operands[0] = .{ .symbol = try symbols.intern(target_text) };
                    inst.operands[1] = .{ .label = try symbols.intern(target_text) };
                },
                .br => {
                    const cond_text = try dict.foldText(allocator, classified.parts[0]);
                    try owned_text.append(cond_text);
                    inst.operands[0] = .{ .reg = try symbols.intern(cond_text) };

                    const true_text = try dict.foldText(allocator, classified.parts[1]);
                    try owned_text.append(true_text);
                    inst.operands[1] = .{ .label = try symbols.intern(true_text) };
                    inst.operands[2] = .{ .label = try symbols.intern(true_text) };

                    const false_text = try dict.foldText(allocator, classified.parts[2]);
                    try owned_text.append(false_text);
                    inst.operands[3] = .{ .label = try symbols.intern(false_text) };
                },
                .br_null => {
                    const reg_text = try dict.foldText(allocator, classified.parts[0]);
                    try owned_text.append(reg_text);
                    inst.operands[0] = .{ .reg = try symbols.intern(reg_text) };

                    const null_text = try dict.foldText(allocator, classified.parts[1]);
                    try owned_text.append(null_text);
                    inst.operands[1] = .{ .label = try symbols.intern(null_text) };
                    inst.operands[2] = .{ .label = try symbols.intern(null_text) };

                    const not_null_text = try dict.foldText(allocator, classified.parts[2]);
                    try owned_text.append(not_null_text);
                    inst.operands[3] = .{ .label = try symbols.intern(not_null_text) };
                },
                .call, .call_indirect, .try_, .panic, .panic_msg, .return_ => {
                    if (classified.inst_form == .return_ and classified.part_count == 1) {
                        const folded = try ownFoldedText(allocator, dict, owned_text, classified.parts[0]);
                        if (symbols.findId(folded)) |id| {
                            inst.operands[0] = .{ .reg = id };
                        } else {
                            inst.operands[0] = .{ .text = folded };
                        }
                    } else if (classified.inst_form == .try_) {
                        const dst = try symbols.intern(classified.parts[0]);
                        const source = try symbols.intern(classified.parts[1]);
                        inst.operands[0] = .{ .reg = dst };
                        inst.operands[1] = .{ .reg = source };
                    } else if (classified.part_count == 2) {
                        const dst = try symbols.intern(classified.parts[0]);
                        inst.operands[0] = .{ .reg = dst };
                        const folded = try ownFoldedText(allocator, dict, owned_text, classified.parts[1]);
                        inst.operands[1] = .{ .text = folded };
                    } else {
                        for (classified.parts[0..classified.part_count], 0..) |part, idx| {
                            const folded = try ownFoldedText(allocator, dict, owned_text, part);
                            inst.operands[idx] = .{ .text = folded };
                        }
                    }
                },
                .raw_cast => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const source = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = source };
                },
                .assume_safe => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const source = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = source };
                },
                .assume_borrow => {
                    const dst = try symbols.intern(classified.parts[0]);
                    const source = try symbols.intern(classified.parts[1]);
                    inst.operands[0] = .{ .reg = dst };
                    inst.operands[1] = .{ .reg = source };
                    if (classified.part_count > 2) {
                        const mode = try ownText(allocator, owned_text, classified.parts[2]);
                        inst.operands[2] = .{ .text = mode };
                    }
                },
                .unknown => {
                    return error.InvalidSyntax;
                },
            }
            try instructions.append(inst);
        },
        .unknown => {
            return error.InvalidSyntax;
        },
        .macro_start, .macro_end, .rep_start, .rep_end, .if_start, .else_, .if_end, .expand => return error.InvalidSyntax,
    }
}

fn includeFileAsConst(
    allocator: std.mem.Allocator,
    kind: enum { str, bytes },
    args: []const u8,
    source_line: u32,
    source_path: ?[]const u8,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.ArrayList(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.ArrayList(Instruction),
    const_decls: *std.ArrayList(ConstDecl),
    function_sigs: *std.ArrayList(FunctionSig),
    owned_text: *std.ArrayList([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    const path_arg = std.mem.trim(u8, args, " \t\r\n");
    if (path_arg.len == 0) return error.InvalidMacroInvocation;

    const include_path_raw = try unquoteString(allocator, path_arg);
    defer allocator.free(include_path_raw);

    const resolved_path = if (std.fs.path.isAbsolute(include_path_raw))
        try allocator.dupe(u8, include_path_raw)
    else if (source_path) |sp| blk: {
        const base = std.fs.path.dirname(sp) orelse ".";
        break :blk try std.fs.path.join(allocator, &.{ base, include_path_raw });
    } else try allocator.dupe(u8, include_path_raw);
    defer allocator.free(resolved_path);

    const file = try std.fs.cwd().openFile(resolved_path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1 << 20);
    defer allocator.free(bytes);

    const const_name = try std.fmt.allocPrint(allocator, "__INCLUDE_{d}_{d}", .{ source_line, const_decls.items.len });
    defer allocator.free(const_name);

    const literal_line = switch (kind) {
        .str => try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"{s}\"", .{ const_name, bytes }),
        .bytes => blk: {
            var hex = std.ArrayList(u8).init(allocator);
            errdefer hex.deinit();
            try hex.appendSlice("hex:");
            for (bytes) |b| {
                try hex.writer().print("\\x{X:0>2}", .{b});
            }
            break :blk try std.fmt.allocPrint(allocator, "@const {s} = {s}", .{ const_name, hex.items });
        },
    };
    defer allocator.free(literal_line);

    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, literal_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
}

fn collectMacroDefinitions(
    allocator: std.mem.Allocator,
    lines: []const SourceLine,
    macros: *std.StringHashMap(MacroDef),
    error_ctx: ?*ErrorContext,
) !void {
    var idx: usize = 0;
    while (idx < lines.len) : (idx += 1) {
        const line = lines[idx];
        recordErrorSourceLine(error_ctx, line.line_no);
        switch (line.classified.kind) {
            .blank_or_comment, .def, .const_decl, .import_decl, .version, .loc_hint, .native, .label, .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl, .instruction, .unknown, .expand, .rep_start, .rep_end, .if_start, .else_, .if_end, .macro_end => {},
            .macro_start => {
                const end = findBlockEnd(lines, idx + 1, .macro_end) orelse return error.UnbalancedMacro;
                const name = line.classified.parts[0];
                const parsed_params = try parseMacroParams(allocator, line.classified.parts[1]);
                errdefer allocator.free(parsed_params.params);
                if (macros.contains(name)) return error.DuplicateDef;
                try macros.put(name, .{
                    .params = parsed_params.params,
                    .variadic_param = parsed_params.variadic_param,
                    .body_start = idx + 1,
                    .body_end = end,
                });
                idx = end;
            },
        }
    }
}

fn isFunctionSigDeclared(sigs: []const FunctionSig, name: []const u8) bool {
    for (sigs) |sig| {
        if (std.mem.eql(u8, sig.name, name)) return true;
    }
    return false;
}

fn parsePrintArgs(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var args = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit();
    }

    var i: usize = 0;
    var start: usize = 0;
    var in_quotes: bool = false;
    var escaped: bool = false;

    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_quotes) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_quotes = false;
            }
        } else {
            if (c == '"') {
                in_quotes = true;
            } else if (c == ',') {
                const arg = std.mem.trim(u8, text[start..i], " \t\r\n");
                if (arg.len > 0) {
                    const arg_dup = try allocator.dupe(u8, arg);
                    try args.append(arg_dup);
                }
                start = i + 1;
            }
        }
    }

    const arg = std.mem.trim(u8, text[start..], " \t\r\n");
    if (arg.len > 0) {
        const arg_dup = try allocator.dupe(u8, arg);
        try args.append(arg_dup);
    }
    return try args.toOwnedSlice();
}

fn unquoteString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var raw = text;
    if (std.mem.startsWith(u8, raw, "utf8:\"") and std.mem.endsWith(u8, raw, "\"")) {
        raw = raw[5 .. raw.len - 1];
    } else if (std.mem.startsWith(u8, raw, "\"") and std.mem.endsWith(u8, raw, "\"")) {
        raw = raw[1 .. raw.len - 1];
    } else {
        return error.InvalidFormatString;
    }
    return try allocator.dupe(u8, raw);
}

const FormatSegmentKind = enum {
    literal,
    placeholder,
};

const Specifier = enum {
    none,
    i64,
    u64,
    f64,
    bytes,
};

const FormatSegment = struct {
    kind: FormatSegmentKind,
    text: []const u8,
    specifier: Specifier,
};

fn parseFormatString(allocator: std.mem.Allocator, fmt_str: []const u8) ![]FormatSegment {
    var segments = std.ArrayList(FormatSegment).init(allocator);
    errdefer {
        for (segments.items) |seg| {
            if (seg.kind == .literal) allocator.free(seg.text);
        }
        segments.deinit();
    }

    var i: usize = 0;
    var start: usize = 0;
    while (i < fmt_str.len) {
        if (fmt_str[i] == '{') {
            if (i > start) {
                const lit_text = try allocator.dupe(u8, fmt_str[start..i]);
                try segments.append(.{
                    .kind = .literal,
                    .text = lit_text,
                    .specifier = .none,
                });
            }

            const close_idx = std.mem.indexOfScalar(u8, fmt_str[i..], '}') orelse return error.UnbalancedPlaceholder;
            const absolute_close = i + close_idx;
            const spec_text = fmt_str[i + 1 .. absolute_close];

            var spec = Specifier.none;
            if (spec_text.len == 0) {
                spec = .none;
            } else if (std.mem.eql(u8, spec_text, ":i") or std.mem.eql(u8, spec_text, ":d")) {
                spec = .i64;
            } else if (std.mem.eql(u8, spec_text, ":u")) {
                spec = .u64;
            } else if (std.mem.eql(u8, spec_text, ":f")) {
                spec = .f64;
            } else if (std.mem.eql(u8, spec_text, ":b") or std.mem.eql(u8, spec_text, ":s")) {
                spec = .bytes;
            } else {
                return error.InvalidSpecifier;
            }

            try segments.append(.{
                .kind = .placeholder,
                .text = &.{},
                .specifier = spec,
            });

            i = absolute_close + 1;
            start = i;
        } else {
            i += 1;
        }
    }

    if (start < fmt_str.len) {
        const lit_text = try allocator.dupe(u8, fmt_str[start..]);
        try segments.append(.{
            .kind = .literal,
            .text = lit_text,
            .specifier = .none,
        });
    }

    return try segments.toOwnedSlice();
}

fn unescapeLength(text: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 2;
        } else {
            i += 1;
        }
        len += 1;
    }
    return len;
}

const EXTERN_SA_FMT_I64 = "@extern sa_fmt_i64(value: i64, base: u32) -> ^ptr!";
const EXTERN_SA_FMT_U64 = "@extern sa_fmt_u64(value: u64, base: u32) -> ^ptr!";
const EXTERN_SA_FMT_F64 = "@extern sa_fmt_f64(value: f64, precision: u32) -> ^ptr!";
const EXTERN_SA_FMT_BYTES = "@extern sa_fmt_bytes(&buf: ptr, len: u64) -> ^ptr!";
const EXTERN_SA_FMT_BUFFER_DATA = "@extern sa_fmt_buffer_data(&buffer: ptr) -> &ptr";
const EXTERN_SA_FMT_BUFFER_LEN = "@extern sa_fmt_buffer_len(&buffer: ptr) -> u64";
const EXTERN_SA_FMT_BUFFER_FREE = "@extern sa_fmt_buffer_free(^buffer: ptr) -> i32!";
const EXTERN_SA_STRING_CONCAT = "@extern sa_string_concat(left: ptr, left_len: u64, right: ptr, right_len: u64) -> ^ptr";

fn ensureExternSigs(
    allocator: std.mem.Allocator,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.ArrayList(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    source_line: u32,
    instructions: *std.ArrayList(Instruction),
    const_decls: *std.ArrayList(ConstDecl),
    function_sigs: *std.ArrayList(FunctionSig),
    owned_text: *std.ArrayList([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    const sigs = function_sigs.items;
    if (!isFunctionSigDeclared(sigs, "sa_fmt_i64")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_I64, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_u64")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_U64, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_f64")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_F64, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_bytes")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_BYTES, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_buffer_data")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_BUFFER_DATA, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_buffer_len")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_BUFFER_LEN, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_fmt_buffer_free")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_FMT_BUFFER_FREE, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
    if (!isFunctionSigDeclared(sigs, "sa_string_concat")) {
        try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, EXTERN_SA_STRING_CONCAT, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
    }
}

fn expandPrintOrFormat(
    allocator: std.mem.Allocator,
    macro_name: []const u8,
    args_text: []const u8,
    source_line: u32,
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.ArrayList(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.ArrayList(Instruction),
    const_decls: *std.ArrayList(ConstDecl),
    function_sigs: *std.ArrayList(FunctionSig),
    owned_text: *std.ArrayList([]const u8),
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    try ensureExternSigs(
        allocator,
        dict,
        symbols,
        loc_table,
        pending_loc,
        source_line,
        instructions,
        const_decls,
        function_sigs,
        owned_text,
        current_package_identity,
        current_package_hash,
    );

    const args = try parsePrintArgs(allocator, args_text);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    if (std.mem.eql(u8, macro_name, "PRINT!")) {
        if (args.len < 1) return error.InvalidMacroInvocation;
        const fmt_str_raw = args[0];
        const format_args = args[1..];

        const fmt_str = try unquoteString(allocator, fmt_str_raw);
        defer allocator.free(fmt_str);

        const segments = try parseFormatString(allocator, fmt_str);
        defer {
            for (segments) |seg| {
                if (seg.kind == .literal) allocator.free(seg.text);
            }
            allocator.free(segments);
        }

        var expected_args: usize = 0;
        for (segments) |seg| {
            if (seg.kind == .placeholder) {
                switch (seg.specifier) {
                    .none, .i64, .u64, .f64 => expected_args += 1,
                    .bytes => expected_args += 2,
                }
            }
        }

        if (expected_args != format_args.len) {
            return error.ArgCountMismatch;
        }

        var var_counter: usize = 0;
        var arg_idx: usize = 0;
        for (segments) |seg| {
            if (seg.kind == .literal) {
                const unescaped_len = unescapeLength(seg.text);
                const const_id = const_decls.items.len;
                const const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, const_id });
                defer allocator.free(const_name);

                const const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"{s}\"", .{ const_name, seg.text });
                defer allocator.free(const_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const print_line = try std.fmt.allocPrint(allocator, "call @sys_print(*{s}, {d})", .{ const_name, unescaped_len });
                defer allocator.free(print_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, print_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
            } else {
                const spec = seg.specifier;
                const fmt_buf_fallible = try std.fmt.allocPrint(allocator, "__fmt_buf_fallible_{d}_{d}", .{ source_line, var_counter });
                const fmt_buf = try std.fmt.allocPrint(allocator, "__fmt_buf_{d}_{d}", .{ source_line, var_counter });
                const fmt_ptr = try std.fmt.allocPrint(allocator, "__fmt_ptr_{d}_{d}", .{ source_line, var_counter });
                const fmt_len = try std.fmt.allocPrint(allocator, "__fmt_len_{d}_{d}", .{ source_line, var_counter });
                const fmt_free_fallible = try std.fmt.allocPrint(allocator, "__fmt_free_fallible_{d}_{d}", .{ source_line, var_counter });
                const fmt_free_ok = try std.fmt.allocPrint(allocator, "__fmt_free_ok_{d}_{d}", .{ source_line, var_counter });
                defer {
                    allocator.free(fmt_buf_fallible);
                    allocator.free(fmt_buf);
                    allocator.free(fmt_ptr);
                    allocator.free(fmt_len);
                    allocator.free(fmt_free_fallible);
                    allocator.free(fmt_free_ok);
                }
                var_counter += 1;

                const call_line = switch (spec) {
                    .none, .i64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_i64({s}, 10)", .{ fmt_buf_fallible, format_args[arg_idx] }),
                    .u64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_u64({s}, 10)", .{ fmt_buf_fallible, format_args[arg_idx] }),
                    .f64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_f64({s}, 6)", .{ fmt_buf_fallible, format_args[arg_idx] }),
                    .bytes => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_bytes(&{s}, {s})", .{ fmt_buf_fallible, format_args[arg_idx], format_args[arg_idx + 1] }),
                };
                defer allocator.free(call_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, call_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                switch (spec) {
                    .none, .i64, .u64, .f64 => arg_idx += 1,
                    .bytes => arg_idx += 2,
                }

                const unpack_line = try std.fmt.allocPrint(allocator, "{s} = ? {s}", .{ fmt_buf, fmt_buf_fallible });
                defer allocator.free(unpack_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, unpack_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const discard_line = try std.fmt.allocPrint(allocator, "! {s}", .{fmt_buf_fallible});
                defer allocator.free(discard_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, discard_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const ptr_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_data(&{s})", .{ fmt_ptr, fmt_buf });
                defer allocator.free(ptr_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const len_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_len(&{s})", .{ fmt_len, fmt_buf });
                defer allocator.free(len_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const print_line = try std.fmt.allocPrint(allocator, "call @sys_print({s}, {s})", .{ fmt_ptr, fmt_len });
                defer allocator.free(print_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, print_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const free_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_free(^{s})", .{ fmt_free_fallible, fmt_buf });
                defer allocator.free(free_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const free_unpack_line = try std.fmt.allocPrint(allocator, "{s} = ? {s}", .{ fmt_free_ok, fmt_free_fallible });
                defer allocator.free(free_unpack_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_unpack_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const free_discard_line = try std.fmt.allocPrint(allocator, "! {s}", .{fmt_free_fallible});
                defer allocator.free(free_discard_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_discard_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
            }
        }
    } else {
        if (args.len < 2) return error.InvalidMacroInvocation;
        const dest_reg = args[0];
        const fmt_str_raw = args[1];
        const format_args = args[2..];

        const fmt_str = try unquoteString(allocator, fmt_str_raw);
        defer allocator.free(fmt_str);

        const segments = try parseFormatString(allocator, fmt_str);
        defer {
            for (segments) |seg| {
                if (seg.kind == .literal) allocator.free(seg.text);
            }
            allocator.free(segments);
        }

        var expected_args: usize = 0;
        for (segments) |seg| {
            if (seg.kind == .placeholder) {
                switch (seg.specifier) {
                    .none, .i64, .u64, .f64 => expected_args += 1,
                    .bytes => expected_args += 2,
                }
            }
        }

        if (expected_args != format_args.len) {
            return error.ArgCountMismatch;
        }

        const SegmentData = struct {
            ptr: []const u8,
            len: []const u8,
            owned: bool,
            owned_buf_name: ?[]const u8,
        };

        var segment_datas = std.ArrayList(SegmentData).init(allocator);
        defer {
            for (segment_datas.items) |sd| {
                allocator.free(sd.ptr);
                allocator.free(sd.len);
                if (sd.owned_buf_name) |ob| allocator.free(ob);
            }
            segment_datas.deinit();
        }

        var var_counter: usize = 0;
        var arg_idx: usize = 0;
        for (segments) |seg| {
            if (seg.kind == .literal) {
                const unescaped_len = unescapeLength(seg.text);
                const const_id = const_decls.items.len;
                const const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, const_id });
                defer allocator.free(const_name);

                const const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"{s}\"", .{ const_name, seg.text });
                defer allocator.free(const_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const ptr_str = try std.fmt.allocPrint(allocator, "*{s}", .{const_name});
                const len_str = try std.fmt.allocPrint(allocator, "{d}", .{unescaped_len});

                try segment_datas.append(.{
                    .ptr = ptr_str,
                    .len = len_str,
                    .owned = false,
                    .owned_buf_name = null,
                });
            } else {
                const spec = seg.specifier;
                const fmt_buf_fallible = try std.fmt.allocPrint(allocator, "__fmt_buf_fallible_{d}_{d}", .{ source_line, var_counter });
                const fmt_buf = try std.fmt.allocPrint(allocator, "__fmt_buf_{d}_{d}", .{ source_line, var_counter });
                const fmt_ptr = try std.fmt.allocPrint(allocator, "__fmt_ptr_{d}_{d}", .{ source_line, var_counter });
                const fmt_len = try std.fmt.allocPrint(allocator, "__fmt_len_{d}_{d}", .{ source_line, var_counter });
                defer {
                    allocator.free(fmt_buf_fallible);
                    allocator.free(fmt_ptr);
                    allocator.free(fmt_len);
                }
                var_counter += 1;

                const call_line = switch (spec) {
                    .none, .i64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_i64({s}, 10)", .{ fmt_buf_fallible, format_args[arg_idx] }),
                    .u64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_u64({s}, 10)", .{ fmt_buf_fallible, format_args[arg_idx] }),
                    .f64 => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_f64({s}, 6)", .{ fmt_buf_fallible, format_args[arg_idx] }),
                    .bytes => try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_bytes(&{s}, {s})", .{ fmt_buf_fallible, format_args[arg_idx], format_args[arg_idx + 1] }),
                };
                defer allocator.free(call_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, call_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                switch (spec) {
                    .none, .i64, .u64, .f64 => arg_idx += 1,
                    .bytes => arg_idx += 2,
                }

                const unpack_line = try std.fmt.allocPrint(allocator, "{s} = ? {s}", .{ fmt_buf, fmt_buf_fallible });
                defer allocator.free(unpack_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, unpack_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const discard_line = try std.fmt.allocPrint(allocator, "! {s}", .{fmt_buf_fallible});
                defer allocator.free(discard_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, discard_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const ptr_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_data(&{s})", .{ fmt_ptr, fmt_buf });
                defer allocator.free(ptr_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const len_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_len(&{s})", .{ fmt_len, fmt_buf });
                defer allocator.free(len_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const ptr_str = try allocator.dupe(u8, fmt_ptr);
                const len_str = try allocator.dupe(u8, fmt_len);

                try segment_datas.append(.{
                    .ptr = ptr_str,
                    .len = len_str,
                    .owned = true,
                    .owned_buf_name = fmt_buf,
                });
            }
        }

        if (segment_datas.items.len == 0) {
            const const_id = const_decls.items.len;
            const const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, const_id });
            defer allocator.free(const_name);

            const const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"\"", .{const_name});
            defer allocator.free(const_line);
            try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

            const empty_const_id = const_decls.items.len;
            const empty_const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, empty_const_id });
            defer allocator.free(empty_const_name);

            const empty_const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"\"", .{empty_const_name});
            defer allocator.free(empty_const_line);
            try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, empty_const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

            const concat_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_string_concat(*{s}, 0, *{s}, 0)", .{ dest_reg, const_name, empty_const_name });
            defer allocator.free(concat_line);
            try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, concat_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
        } else if (segment_datas.items.len == 1) {
            const first = segment_datas.items[0];
            if (first.owned) {
                const assign_line = try std.fmt.allocPrint(allocator, "{s} = ^{s}", .{ dest_reg, first.owned_buf_name.? });
                defer allocator.free(assign_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, assign_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
            } else {
                const const_id = const_decls.items.len;
                const const_name = try std.fmt.allocPrint(allocator, "__PRINT_LIT_{d}_{d}", .{ source_line, const_id });
                defer allocator.free(const_name);

                const const_line = try std.fmt.allocPrint(allocator, "@const {s} = utf8:\"\"", .{const_name});
                defer allocator.free(const_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, const_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                const concat_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_string_concat({s}, {s}, *{s}, 0)", .{ dest_reg, first.ptr, first.len, const_name });
                defer allocator.free(concat_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, concat_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
            }
        } else {
            const left = segment_datas.items[0];
            var left_owned = left.owned;
            var left_buf_name: ?[]const u8 = if (left_owned) try allocator.dupe(u8, left.owned_buf_name.?) else null;
            defer if (left_buf_name) |lbn| allocator.free(lbn);

            var left_ptr = try allocator.dupe(u8, left.ptr);
            var left_len = try allocator.dupe(u8, left.len);
            defer {
                allocator.free(left_ptr);
                allocator.free(left_len);
            }

            var acc_name: ?[]const u8 = null;
            defer if (acc_name) |an| allocator.free(an);

            var i: usize = 1;
            while (i < segment_datas.items.len) : (i += 1) {
                const right = segment_datas.items[i];
                const is_last = (i == segment_datas.items.len - 1);

                const new_acc = if (is_last)
                    dest_reg
                else
                    try std.fmt.allocPrint(allocator, "__fmt_acc_{d}_{d}", .{ source_line, var_counter });
                defer if (!is_last) allocator.free(new_acc);
                if (!is_last) var_counter += 1;

                const concat_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_string_concat({s}, {s}, {s}, {s})", .{ new_acc, left_ptr, left_len, right.ptr, right.len });
                defer allocator.free(concat_line);
                try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, concat_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                if (left_owned) {
                    const free_fallible = try std.fmt.allocPrint(allocator, "__fmt_free_fallible_{d}_{d}", .{ source_line, var_counter });
                    const free_ok = try std.fmt.allocPrint(allocator, "__fmt_free_ok_{d}_{d}", .{ source_line, var_counter });
                    defer {
                        allocator.free(free_fallible);
                        allocator.free(free_ok);
                    }
                    var_counter += 1;

                    const free_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_free(^{s})", .{ free_fallible, left_buf_name.? });
                    defer allocator.free(free_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const unpack_line = try std.fmt.allocPrint(allocator, "{s} = ? {s}", .{ free_ok, free_fallible });
                    defer allocator.free(unpack_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, unpack_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const discard_line = try std.fmt.allocPrint(allocator, "! {s}", .{free_fallible});
                    defer allocator.free(discard_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, discard_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
                }

                if (right.owned) {
                    const free_fallible = try std.fmt.allocPrint(allocator, "__fmt_free_fallible_{d}_{d}", .{ source_line, var_counter });
                    const free_ok = try std.fmt.allocPrint(allocator, "__fmt_free_ok_{d}_{d}", .{ source_line, var_counter });
                    defer {
                        allocator.free(free_fallible);
                        allocator.free(free_ok);
                    }
                    var_counter += 1;

                    const free_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_free(^{s})", .{ free_fallible, right.owned_buf_name.? });
                    defer allocator.free(free_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, free_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const unpack_line = try std.fmt.allocPrint(allocator, "{s} = ? {s}", .{ free_ok, free_fallible });
                    defer allocator.free(unpack_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, unpack_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const discard_line = try std.fmt.allocPrint(allocator, "! {s}", .{free_fallible});
                    defer allocator.free(discard_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, discard_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);
                }

                if (!is_last) {
                    left_owned = true;
                    if (left_buf_name) |lbn| allocator.free(lbn);
                    left_buf_name = try allocator.dupe(u8, new_acc);

                    const new_ptr = try std.fmt.allocPrint(allocator, "__fmt_ptr_{d}_{d}", .{ source_line, var_counter });
                    const new_len = try std.fmt.allocPrint(allocator, "__fmt_len_{d}_{d}", .{ source_line, var_counter });
                    defer {
                        allocator.free(new_ptr);
                        allocator.free(new_len);
                    }
                    var_counter += 1;

                    const ptr_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_data(&{s})", .{ new_ptr, new_acc });
                    defer allocator.free(ptr_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, ptr_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    const len_line = try std.fmt.allocPrint(allocator, "{s} = call @sa_fmt_buffer_len(&{s})", .{ new_len, new_acc });
                    defer allocator.free(len_line);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, len_line, source_line, instructions, const_decls, function_sigs, owned_text, current_package_identity, current_package_hash);

                    allocator.free(left_ptr);
                    allocator.free(left_len);
                    left_ptr = try allocator.dupe(u8, new_ptr);
                    left_len = try allocator.dupe(u8, new_len);

                    if (acc_name) |an| allocator.free(an);
                    acc_name = try allocator.dupe(u8, new_acc);
                } else {
                    left_owned = false;
                    if (left_buf_name) |lbn| {
                        allocator.free(lbn);
                        left_buf_name = null;
                    }
                }
            }
        }
    }
}

fn emitRange(
    allocator: std.mem.Allocator,
    lines: []const SourceLine,
    start: usize,
    end: usize,
    depth: u16,
    source_line_override: ?u32,
    replacements: []const Replacement,
    top_level: bool,
    macros: *std.StringHashMap(MacroDef),
    dict: *DefDict,
    symbols: *SymbolTable,
    loc_table: *std.ArrayList(?common_upstream.UpstreamLoc),
    pending_loc: *?common_upstream.UpstreamLoc,
    instructions: *std.ArrayList(Instruction),
    const_decls: *std.ArrayList(ConstDecl),
    function_sigs: *std.ArrayList(FunctionSig),
    owned_text: *std.ArrayList([]const u8),
    error_ctx: ?*ErrorContext,
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
) !void {
    if (depth > 256) return error.MacroRecursionLimit;

    var idx = start;
    while (idx < end) : (idx += 1) {
        const line = lines[idx];
        const source_line = source_line_override orelse line.line_no;
        const effective_package_identity = line.package_identity orelse current_package_identity;
        recordErrorSourceLine(error_ctx, source_line);

        switch (line.classified.kind) {
            .blank_or_comment, .import_decl, .version => {},
            .const_decl => {
                if (!top_level) return error.InvalidMacroDefinitionContext;
                const upstream_loc = takePendingLoc(pending_loc);
                errdefer if (upstream_loc) |loc| allocator.free(loc.file);
                var decl = try common_const_decl.parseConstDecl(
                    allocator,
                    line.text,
                    source_line,
                    @intCast(instructions.items.len),
                    upstream_loc,
                );
                errdefer decl.deinit(allocator);
                _ = try symbols.intern(decl.name);
                try const_decls.append(decl);
            },
            .loc_hint => {
                const line_no = try std.fmt.parseInt(u32, line.classified.parts[1], 10);
                const col_no = try std.fmt.parseInt(u32, line.classified.parts[2], 10);
                try setPendingLoc(allocator, pending_loc, line.classified.parts[0], line_no, col_no);
            },
            .def, .label, .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl, .instruction, .native, .unknown => {
                const should_render = source_line_override != null or replacements.len != 0;
                if (should_render) {
                    const rendered = try renderWithReplacements(allocator, line.text, replacements);
                    try owned_text.append(rendered);
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, rendered, source_line, instructions, const_decls, function_sigs, owned_text, effective_package_identity, line.package_source_sha256 orelse current_package_hash);
                } else {
                    try emitParsedLine(allocator, dict, symbols, loc_table, pending_loc, line.text, source_line, instructions, const_decls, function_sigs, owned_text, effective_package_identity, line.package_source_sha256 orelse current_package_hash);
                }
            },
            .macro_start => {
                if (!top_level) return error.InvalidMacroDefinitionContext;
                const def = macros.get(line.classified.parts[0]) orelse return error.InvalidMacroInvocation;
                idx = def.body_end;
            },
            .macro_end => return error.UnbalancedMacro,
            .rep_start => {
                const count_text = try dict.foldText(allocator, line.classified.parts[0]);
                try owned_text.append(count_text);
                const count = try std.fmt.parseInt(usize, count_text, 10);
                const rep_end = findNestedRepEnd(lines, idx + 1) orelse return error.UnbalancedRep;

                var rep_index: usize = 0;
                while (rep_index < count) : (rep_index += 1) {
                    const rep_value = try std.fmt.allocPrint(allocator, "{d}", .{rep_index});
                    defer allocator.free(rep_value);

                    const combined = if (replacements.len == 0) blk: {
                        var list = std.ArrayList(Replacement).init(allocator);
                        errdefer list.deinit();
                        try list.append(.{ .needle = "%i", .replacement = rep_value });
                        break :blk try list.toOwnedSlice();
                    } else blk: {
                        var list = std.ArrayList(Replacement).init(allocator);
                        errdefer list.deinit();
                        try list.appendSlice(replacements);
                        try list.append(.{ .needle = "%i", .replacement = rep_value });
                        break :blk try list.toOwnedSlice();
                    };
                    defer allocator.free(combined);

                    try emitRange(
                        allocator,
                        lines,
                        idx + 1,
                        rep_end,
                        depth + 1,
                        source_line_override orelse line.line_no,
                        combined,
                        false,
                        macros,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        error_ctx,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                }

                idx = rep_end;
            },
            .rep_end => return error.UnbalancedRep,
            .if_start => {
                const bounds = findNestedIfBounds(lines, idx + 1) orelse return error.InvalidMacroInvocation;
                const condition_text = if (replacements.len == 0)
                    try allocator.dupe(u8, line.classified.parts[0])
                else
                    try renderWithReplacements(allocator, line.classified.parts[0], replacements);
                defer allocator.free(condition_text);
                try owned_text.append(try allocator.dupe(u8, condition_text));

                const condition_true = try macroConditionIsTrue(condition_text);
                const selected_start = if (condition_true) idx + 1 else (if (bounds.else_idx) |else_idx| else_idx + 1 else bounds.end_idx);
                const selected_end = if (condition_true) (bounds.else_idx orelse bounds.end_idx) else bounds.end_idx;
                if (selected_start < selected_end) {
                    try emitRange(
                        allocator,
                        lines,
                        selected_start,
                        selected_end,
                        depth + 1,
                        source_line_override orelse line.line_no,
                        replacements,
                        false,
                        macros,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        error_ctx,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                }
                idx = bounds.end_idx;
            },
            .else_, .if_end => return error.InvalidMacroInvocation,
            .expand => {
                const rendered_line = if (replacements.len == 0) line.text else blk: {
                    const rendered = try renderWithReplacements(allocator, line.text, replacements);
                    try owned_text.append(rendered);
                    break :blk rendered;
                };
                const rendered_classified = classifier.classifyLine(rendered_line);
                if (rendered_classified.kind != .expand) return error.InvalidSyntax;
                const macro_name = rendered_classified.parts[0];
                if (std.mem.eql(u8, macro_name, "PRINT!") or std.mem.eql(u8, macro_name, "FORMAT!")) {
                    try expandPrintOrFormat(
                        allocator,
                        macro_name,
                        rendered_classified.parts[1],
                        source_line,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                } else {
                    const def = macros.get(macro_name) orelse return error.InvalidMacroInvocation;
                    const args = try parseTokenList(allocator, rendered_classified.parts[1]);
                    defer allocator.free(args);
                    if (def.variadic_param) |variadic_param| {
                        if (args.len < def.params.len) return error.InvalidMacroInvocation;
                        var local_replacements = std.ArrayList(Replacement).init(allocator);
                        errdefer local_replacements.deinit();
                        for (def.params, 0..) |param, iarg| {
                            try local_replacements.append(.{ .needle = param, .replacement = args[iarg] });
                        }
                        const variadic_args = args[def.params.len..];
                        const joined = try joinTokens(allocator, variadic_args);
                        defer allocator.free(joined);
                        try local_replacements.append(.{ .needle = variadic_param, .replacement = joined });
                        const local_slice = try local_replacements.toOwnedSlice();
                        defer allocator.free(local_slice);
                        try emitRange(
                            allocator,
                            lines,
                            def.body_start,
                            def.body_end,
                            depth + 1,
                            source_line_override orelse line.line_no,
                            local_slice,
                            false,
                            macros,
                            dict,
                            symbols,
                            loc_table,
                            pending_loc,
                            instructions,
                            const_decls,
                            function_sigs,
                            owned_text,
                            error_ctx,
                            effective_package_identity,
                            line.package_source_sha256 orelse current_package_hash,
                        );
                        continue;
                    }

                    if (args.len != def.params.len) return error.InvalidMacroInvocation;

                    var local_replacements = std.ArrayList(Replacement).init(allocator);
                    errdefer local_replacements.deinit();
                    for (def.params, 0..) |param, iarg| {
                        try local_replacements.append(.{ .needle = param, .replacement = args[iarg] });
                    }
                    const local_slice = try local_replacements.toOwnedSlice();
                    defer allocator.free(local_slice);
                    try emitRange(
                        allocator,
                        lines,
                        def.body_start,
                        def.body_end,
                        depth + 1,
                        source_line_override orelse line.line_no,
                        local_slice,
                        false,
                        macros,
                        dict,
                        symbols,
                        loc_table,
                        pending_loc,
                        instructions,
                        const_decls,
                        function_sigs,
                        owned_text,
                        error_ctx,
                        effective_package_identity,
                        line.package_source_sha256 orelse current_package_hash,
                    );
                }
            },
        }
    }
}

fn collectLocTableEntries(
    allocator: std.mem.Allocator,
    instructions: []const Instruction,
) !LocTable {
    var table = std.ArrayList(?common_upstream.UpstreamLoc).init(allocator);
    errdefer table.deinit();

    for (instructions) |item| {
        const keep_loc = switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .label => false,
            else => true,
        };
        if (keep_loc) {
            if (item.upstream_loc) |loc| {
                const file_copy = try allocator.dupe(u8, loc.file);
                errdefer allocator.free(file_copy);
                try table.append(.{
                    .file = file_copy,
                    .line = loc.line,
                    .col = loc.col,
                });
            } else {
                try table.append(null);
            }
        } else {
            try table.append(null);
        }
    }

    return try table.toOwnedSlice();
}

pub fn scanSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    line_package_identities: []const ?[]const u8,
    line_package_hashes: []const ?[32]u8,
) ![]SourceLine {
    var lines = std.ArrayList(SourceLine).init(allocator);
    errdefer lines.deinit();

    var iterator = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (iterator.next()) |raw_line| : (line_no += 1) {
        const idx: usize = @intCast(line_no - 1);
        const package_identity = if (idx < line_package_identities.len) line_package_identities[idx] else null;
        const package_source_sha256 = if (idx < line_package_hashes.len) line_package_hashes[idx] else null;
        try lines.append(.{
            .line_no = line_no,
            .text = raw_line,
            .classified = classifier.classifyLine(raw_line),
            .package_identity = package_identity,
            .package_source_sha256 = package_source_sha256,
        });
    }

    return try lines.toOwnedSlice();
}

fn appendOwnedSource(out: *std.ArrayList(u8), source: []const u8) !void {
    if (source.len == 0) return;
    try out.appendSlice(source);
    if (source[source.len - 1] != '\n') try out.append('\n');
}

fn parseImportPath(line: []const u8) ?[]const u8 {
    const classified = classifier.classifyLine(line);
    if (classified.kind != .import_decl) return null;
    return classified.parts[0];
}

fn readImportFile(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    resolve_ctx: ?ResolveContext,
) !pkg_resolver.ResolvedImport {
    const deps = if (resolve_ctx) |ctx| ctx.dependencies else &.{};
    var options: pkg_resolver.ResolveOptions = .{};
    if (resolve_ctx) |ctx| options = ctx.options;
    return try pkg_resolver.resolveImport(allocator, deps, base_dir, import_path, options);
}

fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return try std.fs.path.join(allocator, parts);
}

fn pathStem(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return base[0..dot];
}

fn packageNamespacePrefix(allocator: std.mem.Allocator, package_identity: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, package_identity, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidPath;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("pkg_");

    for (trimmed) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9' => try out.append(c),
            '_' => try out.appendSlice("_us_"),
            '.' => try out.appendSlice("_dot_"),
            '/' => try out.appendSlice("_slash_"),
            '-' => try out.appendSlice("_dash_"),
            ':' => try out.appendSlice("_colon_"),
            '@' => try out.appendSlice("_at_"),
            '+' => try out.appendSlice("_plus_"),
            '~' => try out.appendSlice("_tilde_"),
            else => {
                try out.appendSlice("_x");
                try out.writer().print("{X:0>2}_", .{c});
            },
        }
    }

    return try out.toOwnedSlice();
}

fn rememberPackageIdentity(
    allocator: std.mem.Allocator,
    seen_package_identities: *std.StringHashMap(void),
    package_identity: []const u8,
) ![]const u8 {
    if (seen_package_identities.getKeyPtr(package_identity)) |key_ptr| return key_ptr.*;

    const copy = try allocator.dupe(u8, package_identity);
    errdefer allocator.free(copy);
    try seen_package_identities.put(copy, {});
    return copy;
}

fn containsText(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn rewritePackageLayoutExpr(
    allocator: std.mem.Allocator,
    expr: []const u8,
    prefix: []const u8,
    local_defs: []const []const u8,
) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var idx: usize = 0;
    while (idx < expr.len) {
        if (std.ascii.isAlphabetic(expr[idx]) or expr[idx] == '_') {
            const start = idx;
            idx += 1;
            while (idx < expr.len and (std.ascii.isAlphanumeric(expr[idx]) or expr[idx] == '_' or expr[idx] == '.')) : (idx += 1) {}
            const token = expr[start..idx];
            if (containsText(local_defs, token)) {
                try out.appendSlice(prefix);
                try out.append('.');
                try out.appendSlice(token);
            } else {
                try out.appendSlice(token);
            }
            continue;
        }
        try out.append(expr[idx]);
        idx += 1;
    }

    return try out.toOwnedSlice();
}

fn rewritePackageLayoutSource(
    allocator: std.mem.Allocator,
    source: []const u8,
    package_identity: []const u8,
) ![]u8 {
    const prefix = try packageNamespacePrefix(allocator, package_identity);
    defer allocator.free(prefix);

    var local_defs = std.ArrayList([]const u8).init(allocator);
    defer local_defs.deinit();

    var collector = std.mem.splitScalar(u8, source, '\n');
    while (collector.next()) |raw_line| {
        const classified = classifier.classifyLine(raw_line);
        if (classified.kind == .def) {
            try local_defs.append(classified.parts[0]);
        }
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var iterator = std.mem.splitScalar(u8, source, '\n');
    var first_line = true;
    while (iterator.next()) |raw_line| {
        if (!first_line) try out.append('\n');
        first_line = false;

        const classified = classifier.classifyLine(raw_line);
        switch (classified.kind) {
            .def => {
                const rewritten_rhs = try rewritePackageLayoutExpr(allocator, classified.parts[1], prefix, local_defs.items);
                defer allocator.free(rewritten_rhs);
                try out.appendSlice("#def ");
                try out.appendSlice(prefix);
                try out.append('.');
                try out.appendSlice(classified.parts[0]);
                try out.appendSlice(" = ");
                try out.appendSlice(rewritten_rhs);
            },
            else => try out.appendSlice(raw_line),
        }
    }

    if (source.len != 0 and source[source.len - 1] == '\n') {
        try out.append('\n');
    }

    return try out.toOwnedSlice();
}

fn injectImportedFile(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line_package_identities: *std.ArrayList(?[]const u8),
    line_package_hashes: *std.ArrayList(?[32]u8),
    imported: *pkg_resolver.ResolvedImport,
    active_paths: *std.StringHashMap(void),
    seen_paths: *std.StringHashMap(void),
    seen_package_identities: *std.StringHashMap(void),
    owned_paths: *std.ArrayList([]u8),
    layout_versions: *std.ArrayList(LayoutVersion),
    error_ctx: ?*ErrorContext,
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
    resolve_ctx: ?ResolveContext,
) anyerror!void {
    const entry_path = imported.entry_path;
    if (!std.mem.endsWith(u8, entry_path, ".sa")) return;

    const effective_package_identity = if (imported.package_identity) |identity| blk: {
        break :blk try rememberPackageIdentity(allocator, seen_package_identities, identity);
    } else if (!imported.is_global) blk: {
        if (current_package_identity) |identity| {
            break :blk try rememberPackageIdentity(allocator, seen_package_identities, identity);
        }
        break :blk null;
    } else null;

    const import_dir = std.fs.path.dirname(entry_path) orelse ".";
    const stem = pathStem(entry_path);
    const iface_name = try std.fmt.allocPrint(allocator, "{s}.sai", .{stem});
    defer allocator.free(iface_name);
    const layout_name = try std.fmt.allocPrint(allocator, "{s}.sal", .{stem});
    defer allocator.free(layout_name);

    const injected_root = struct {
        fn run(
            allocator2: std.mem.Allocator,
            out2: *std.ArrayList(u8),
            line_package_identities2: *std.ArrayList(?[]const u8),
            line_package_hashes2: *std.ArrayList(?[32]u8),
            base_dir: []const u8,
            file_name: []const u8,
            active_paths2: *std.StringHashMap(void),
            seen_paths2: *std.StringHashMap(void),
            seen_package_identities2: *std.StringHashMap(void),
            owned_paths2: *std.ArrayList([]u8),
            layout_versions2: *std.ArrayList(LayoutVersion),
            error_ctx2: ?*ErrorContext,
            current_package_identity2: ?[]const u8,
            current_package_hash2: ?[32]u8,
            resolve_ctx2: ?ResolveContext,
        ) anyerror!void {
            var injected = try readImportFile(allocator2, base_dir, file_name, resolve_ctx2);
            defer injected.deinit(allocator2);
            if (active_paths2.contains(injected.entry_path) or seen_paths2.contains(injected.entry_path)) return;
            owned_paths2.append(injected.entry_path) catch |err| {
                injected.deinit(allocator2);
                return err;
            };
            injected.entry_path_owned = false;
            try seen_paths2.put(injected.entry_path, {});
            try active_paths2.put(injected.entry_path, {});
            defer _ = active_paths2.remove(injected.entry_path);

            const effective_child_package_identity = if (injected.package_identity) |identity|
                identity
            else if (!injected.is_global)
                current_package_identity2
            else
                null;
            const is_layout_file = std.mem.endsWith(u8, injected.entry_path, ".sal");
            var rewritten_source: ?[]u8 = null;
            defer if (rewritten_source) |rewritten| allocator2.free(rewritten);
            const expanded_source = if (is_layout_file) blk: {
                if (effective_child_package_identity) |identity| {
                    const rewritten = try rewritePackageLayoutSource(allocator2, injected.source, identity);
                    rewritten_source = rewritten;
                    break :blk rewritten;
                }
                break :blk injected.source;
            } else injected.source;

            if (is_layout_file) {
                try recordLayoutVersion(allocator2, layout_versions2, injected.entry_path, injected.source);
            }
            const injected_dir = std.fs.path.dirname(injected.entry_path) orelse ".";
            try expandImportsInto(
                allocator2,
                out2,
                line_package_identities2,
                line_package_hashes2,
                expanded_source,
                injected_dir,
                active_paths2,
                seen_paths2,
                seen_package_identities2,
                owned_paths2,
                layout_versions2,
                error_ctx2,
                effective_child_package_identity,
                current_package_hash2,
                resolve_ctx2,
            );
        }
    }.run;

    const iface_path = try pathJoin(allocator, &.{ import_dir, iface_name });
    defer allocator.free(iface_path);
    if (std.fs.cwd().access(iface_path, .{})) |_| {
        try injected_root(
            allocator,
            out,
            line_package_identities,
            line_package_hashes,
            import_dir,
            iface_name,
            active_paths,
            seen_paths,
            seen_package_identities,
            owned_paths,
            layout_versions,
            error_ctx,
            effective_package_identity,
            current_package_hash,
            resolve_ctx,
        );
    } else |_| {}

    const layout_path = try pathJoin(allocator, &.{ import_dir, layout_name });
    defer allocator.free(layout_path);
    if (std.fs.cwd().access(layout_path, .{})) |_| {
        try injected_root(
            allocator,
            out,
            line_package_identities,
            line_package_hashes,
            import_dir,
            layout_name,
            active_paths,
            seen_paths,
            seen_package_identities,
            owned_paths,
            layout_versions,
            error_ctx,
            effective_package_identity,
            current_package_hash,
            resolve_ctx,
        );
    } else |_| {}
}

fn expandImportsInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    line_package_identities: *std.ArrayList(?[]const u8),
    line_package_hashes: *std.ArrayList(?[32]u8),
    source: []const u8,
    base_dir: []const u8,
    active_paths: *std.StringHashMap(void),
    seen_paths: *std.StringHashMap(void),
    seen_package_identities: *std.StringHashMap(void),
    owned_paths: *std.ArrayList([]u8),
    layout_versions: *std.ArrayList(LayoutVersion),
    error_ctx: ?*ErrorContext,
    current_package_identity: ?[]const u8,
    current_package_hash: ?[32]u8,
    resolve_ctx: ?ResolveContext,
) !void {
    var iterator = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (iterator.next()) |raw_line| : (line_no += 1) {
        recordErrorSourceLine(error_ctx, line_no);
        if (parseImportPath(raw_line)) |import_path| {
            var imported = try readImportFile(allocator, base_dir, import_path, resolve_ctx);
            const imported_package_identity = if (imported.package_identity) |identity| blk: {
                break :blk try rememberPackageIdentity(allocator, seen_package_identities, identity);
            } else if (!imported.is_global) blk: {
                if (current_package_identity) |identity| {
                    break :blk try rememberPackageIdentity(allocator, seen_package_identities, identity);
                }
                break :blk null;
            } else null;
            const imported_package_hash = if (imported.package_identity != null)
                imported.source_sha256 orelse current_package_hash
            else
                current_package_hash;

            if (active_paths.contains(imported.entry_path)) {
                imported.deinit(allocator);
                return error.ImportCycle;
            }
            if (seen_paths.contains(imported.entry_path)) {
                imported.deinit(allocator);
                continue;
            }
            if (std.mem.endsWith(u8, imported.entry_path, ".sal")) {
                try recordLayoutVersion(allocator, layout_versions, imported.entry_path, imported.source);
            }
            owned_paths.append(imported.entry_path) catch |err| {
                imported.deinit(allocator);
                return err;
            };
            imported.entry_path_owned = false;
            defer imported.deinit(allocator);
            try seen_paths.put(imported.entry_path, {});
            try active_paths.put(imported.entry_path, {});
            defer _ = active_paths.remove(imported.entry_path);

            const import_dir = std.fs.path.dirname(imported.entry_path) orelse ".";
            try injectImportedFile(
                allocator,
                out,
                line_package_identities,
                line_package_hashes,
                &imported,
                active_paths,
                seen_paths,
                seen_package_identities,
                owned_paths,
                layout_versions,
                error_ctx,
                current_package_identity,
                imported_package_hash,
                resolve_ctx,
            );
            const is_layout_file = std.mem.endsWith(u8, imported.entry_path, ".sal");
            var rewritten_source: ?[]u8 = null;
            defer if (rewritten_source) |rewritten| allocator.free(rewritten);
            const expanded_source = if (is_layout_file) blk: {
                if (imported_package_identity) |identity| {
                    const rewritten = try rewritePackageLayoutSource(allocator, imported.source, identity);
                    rewritten_source = rewritten;
                    break :blk rewritten;
                }
                break :blk imported.source;
            } else imported.source;
            try expandImportsInto(
                allocator,
                out,
                line_package_identities,
                line_package_hashes,
                expanded_source,
                import_dir,
                active_paths,
                seen_paths,
                seen_package_identities,
                owned_paths,
                layout_versions,
                error_ctx,
                imported_package_identity,
                imported_package_hash,
                resolve_ctx,
            );
            continue;
        }

        try appendExpandedLine(out, line_package_identities, line_package_hashes, raw_line, current_package_identity, current_package_hash);
    }
}

pub fn expandImports(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: ?[]const u8,
    error_ctx: ?*ErrorContext,
    resolve_ctx: ?ResolveContext,
) !ImportExpansion {
    var active_paths = std.StringHashMap(void).init(allocator);
    errdefer active_paths.deinit();

    var seen_paths = std.StringHashMap(void).init(allocator);
    errdefer seen_paths.deinit();

    var seen_package_identities = std.StringHashMap(void).init(allocator);
    errdefer {
        var pkg_it = seen_package_identities.iterator();
        while (pkg_it.next()) |entry| allocator.free(entry.key_ptr.*);
        seen_package_identities.deinit();
    }

    var line_package_identities = std.ArrayList(?[]const u8).init(allocator);
    errdefer line_package_identities.deinit();

    var line_package_hashes = std.ArrayList(?[32]u8).init(allocator);
    errdefer line_package_hashes.deinit();

    var owned_paths = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (owned_paths.items) |path| allocator.free(path);
        owned_paths.deinit();
    }
    var layout_versions = std.ArrayList(LayoutVersion).init(allocator);
    errdefer {
        for (layout_versions.items) |*layout_version| layout_version.deinit(allocator);
        layout_versions.deinit();
    }

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    const base_dir = if (source_path) |path| std.fs.path.dirname(path) orelse "." else ".";
    if (source_path) |path| {
        const source_full = if (std.fs.path.isAbsolute(path))
            try allocator.dupe(u8, path)
        else
            try std.fs.cwd().realpathAlloc(allocator, path);
        owned_paths.append(source_full) catch |err| {
            allocator.free(source_full);
            return err;
        };
        try active_paths.put(source_full, {});
        try seen_paths.put(source_full, {});

        if (std.mem.endsWith(u8, source_full, ".sal")) {
            try recordLayoutVersion(allocator, &layout_versions, source_full, source);
        }
    }

    const current_package_identity = if (resolve_ctx) |ctx|
        if (ctx.package_identity) |identity|
            try rememberPackageIdentity(allocator, &seen_package_identities, identity)
        else
            null
    else
        null;
    try expandImportsInto(
        allocator,
        &out,
        &line_package_identities,
        &line_package_hashes,
        source,
        base_dir,
        &active_paths,
        &seen_paths,
        &seen_package_identities,
        &owned_paths,
        &layout_versions,
        error_ctx,
        current_package_identity,
        null,
        resolve_ctx,
    );

    return .{
        .source = try out.toOwnedSlice(),
        .active_paths = active_paths,
        .seen_paths = seen_paths,
        .seen_package_identities = seen_package_identities,
        .line_package_identities = line_package_identities,
        .line_package_hashes = line_package_hashes,
        .owned_paths = owned_paths,
        .layout_versions = layout_versions,
    };
}

pub fn findFirstForbiddenLine(source: []const u8) ?ForbiddenLine {
    var iterator = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (iterator.next()) |raw_line| : (line_no += 1) {
        const classified = classifier.classifyLine(raw_line);
        if (classified.kind == .native or classified.kind == .import_decl or classified.kind == .const_decl) continue;
        if (forbidden.findForbiddenSyntax(raw_line)) |hit| {
            return .{ .line_no = line_no, .hit = hit };
        }
    }
    return null;
}

fn flattenInternal(
    allocator: std.mem.Allocator,
    source: []const u8,
    source_path: ?[]const u8,
    error_ctx: ?*ErrorContext,
    resolve_ctx: ?ResolveContext,
) !FlattenResult {
    if (error_ctx) |ctx| ctx.source_line = null;
    var expanded = try expandImports(allocator, source, source_path, error_ctx, resolve_ctx);
    defer expanded.deinit(allocator);

    if (findFirstForbiddenLine(expanded.source)) |_| {
        return error.ForbiddenSyntax;
    }

    var dict = DefDict.init(allocator);
    errdefer dict.deinit();
    var symbols = SymbolTable.init(allocator);
    errdefer symbols.deinit();
    var instructions = std.ArrayList(Instruction).init(allocator);
    errdefer instructions.deinit();
    var const_decls = std.ArrayList(ConstDecl).init(allocator);
    errdefer {
        for (const_decls.items) |*decl| decl.deinit(allocator);
        const_decls.deinit();
    }
    var function_sigs = std.ArrayList(FunctionSig).init(allocator);
    errdefer {
        for (function_sigs.items) |*sig_item| sig_item.deinit(allocator);
        function_sigs.deinit();
    }
    var owned_text = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (owned_text.items) |text| allocator.free(text);
        owned_text.deinit();
    }
    var loc_table = std.ArrayList(?common_upstream.UpstreamLoc).init(allocator);
    errdefer {
        for (loc_table.items) |entry| {
            if (entry) |loc| allocator.free(loc.file);
        }
        loc_table.deinit();
    }
    var pending_loc: ?common_upstream.UpstreamLoc = null;
    errdefer if (pending_loc) |loc| allocator.free(loc.file);

    var macros = std.StringHashMap(MacroDef).init(allocator);
    defer deinitMacroMap(allocator, &macros);

    const lines = try scanSource(allocator, expanded.source, expanded.line_package_identities.items[0..], expanded.line_package_hashes.items[0..]);
    defer allocator.free(lines);

    try collectMacroDefinitions(allocator, lines, &macros, error_ctx);
    const empty_replacements = [_]Replacement{};
    emitRange(
        allocator,
        lines,
        0,
        lines.len,
        0,
        null,
        empty_replacements[0..],
        true,
        &macros,
        &dict,
        &symbols,
        &loc_table,
        &pending_loc,
        &instructions,
        &const_decls,
        &function_sigs,
        &owned_text,
        error_ctx,
        null,
        null,
    ) catch |err| return err;
    if (pending_loc) |loc| {
        allocator.free(loc.file);
        pending_loc = null;
    }

    const loc_table_slice = try collectLocTableEntries(allocator, instructions.items);
    const layout_versions = try expanded.layout_versions.toOwnedSlice();
    const package_identities = expanded.seen_package_identities;
    expanded.seen_package_identities = std.StringHashMap(void).init(allocator);
    loc_table.deinit();

    const function_sigs_slice = try function_sigs.toOwnedSlice();

    // Filter test functions from function_sigs
    var test_sigs_list = std.ArrayList(FunctionSig).init(allocator);
    errdefer test_sigs_list.deinit();
    for (function_sigs_slice) |sig| {
        if (sig.kind == .test_func) {
            try test_sigs_list.append(sig);
        }
    }

    return .{
        .instructions = try instructions.toOwnedSlice(),
        .const_decls = try const_decls.toOwnedSlice(),
        .function_sigs = function_sigs_slice,
        .test_sigs = try test_sigs_list.toOwnedSlice(),
        .def_dict = dict,
        .symbols = symbols,
        .loc_table = loc_table_slice,
        .layout_versions = layout_versions,
        .package_identities = package_identities,
        .owned_text = try owned_text.toOwnedSlice(),
        .trap = null,
    };
}

pub fn flatten(allocator: std.mem.Allocator, source: []const u8) !FlattenResult {
    return flattenInternal(allocator, source, null, null, null);
}

pub fn flattenWithContext(allocator: std.mem.Allocator, source: []const u8, error_ctx: ?*ErrorContext) !FlattenResult {
    return flattenInternal(allocator, source, null, error_ctx, null);
}

pub fn flattenFileWithContext(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    error_ctx: ?*ErrorContext,
) !FlattenResult {
    return flattenInternal(allocator, source, source_path, error_ctx, null);
}

pub fn flattenFile(allocator: std.mem.Allocator, source_path: []const u8, source: []const u8) !FlattenResult {
    return flattenInternal(allocator, source, source_path, null, null);
}

pub fn flattenWithPackages(
    allocator: std.mem.Allocator,
    source: []const u8,
    resolve_ctx: ResolveContext,
) !FlattenResult {
    return flattenInternal(allocator, source, null, null, resolve_ctx);
}

pub fn flattenWithContextAndPackages(
    allocator: std.mem.Allocator,
    source: []const u8,
    error_ctx: ?*ErrorContext,
    resolve_ctx: ResolveContext,
) !FlattenResult {
    return flattenInternal(allocator, source, null, error_ctx, resolve_ctx);
}

pub fn flattenFileWithPackages(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    resolve_ctx: ResolveContext,
) !FlattenResult {
    return flattenInternal(allocator, source, source_path, null, resolve_ctx);
}

pub fn flattenFileWithContextAndPackages(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    error_ctx: ?*ErrorContext,
    resolve_ctx: ResolveContext,
) !FlattenResult {
    return flattenInternal(allocator, source, source_path, error_ctx, resolve_ctx);
}

const MacroPbtProgram = struct {
    source: []u8,
    base_name: []u8,
    acc_name: []u8,
    alloc_size: u64,
    count: u8,

    fn deinit(self: *MacroPbtProgram, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
        allocator.free(self.base_name);
        allocator.free(self.acc_name);
        self.* = undefined;
    }
};

fn buildMacroPbtProgram(allocator: std.mem.Allocator, random: std.Random, iter: usize) !MacroPbtProgram {
    const count = random.intRangeAtMost(u8, 0, 4);
    const alloc_size = random.intRangeAtMost(u64, 1, 64);
    const salt = random.intRangeAtMost(u32, 0, 9999);

    const base_name = try std.fmt.allocPrint(allocator, "base_{d}_{d}", .{ iter, salt });
    errdefer allocator.free(base_name);
    const acc_name = try std.fmt.allocPrint(allocator, "acc_{d}_{d}", .{ iter, salt });
    errdefer allocator.free(acc_name);

    var source = std.ArrayList(u8).init(allocator);
    errdefer source.deinit();
    const writer = source.writer();
    try writer.writeAll(
        \\#def REP_COUNT = 
    );
    try writer.print("{d}\n", .{count});
    try writer.writeAll(
        \\[MACRO] INIT %acc, %base
        \\    %acc = add %base, 0
        \\[END_MACRO]
        \\
        \\[MACRO] CHAIN %acc, %base
        \\    EXPAND INIT %acc, %base
        \\    [REP REP_COUNT]
        \\        tmp_%i = add %acc, %i
        \\    [END_REP]
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\
    );
    try writer.print("    {s} = alloc {d}\n", .{ base_name, alloc_size });
    try writer.print("    EXPAND CHAIN {s}, {s}\n", .{ acc_name, base_name });
    try writer.print("    return {s}\n", .{acc_name});

    return .{
        .source = try source.toOwnedSlice(),
        .base_name = base_name,
        .acc_name = acc_name,
        .alloc_size = alloc_size,
        .count = count,
    };
}

const ArithmeticExpr = struct {
    text: []u8,
    value: i64,

    fn deinit(self: *ArithmeticExpr, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

fn buildArithmeticExpr(allocator: std.mem.Allocator, random: std.Random, depth: u8) !ArithmeticExpr {
    if (depth == 0 or random.intRangeAtMost(u8, 0, 3) == 0) {
        const raw = @as(i64, @intCast(random.intRangeAtMost(u32, 0, 9)));
        const signed = if (random.intRangeLessThan(u8, 0, 2) == 0) raw else -raw;
        return .{
            .text = try std.fmt.allocPrint(allocator, "{d}", .{signed}),
            .value = signed,
        };
    }

    var left = try buildArithmeticExpr(allocator, random, depth - 1);
    defer left.deinit(allocator);
    var right = try buildArithmeticExpr(allocator, random, depth - 1);
    defer right.deinit(allocator);

    const op_index = random.intRangeLessThan(u8, 0, 3);
    const op: u8 = switch (op_index) {
        0 => '+',
        1 => '-',
        else => '*',
    };
    const value: i64 = switch (op) {
        '+' => left.value + right.value,
        '-' => left.value - right.value,
        '*' => left.value * right.value,
        else => unreachable,
    };

    return .{
        .text = try std.fmt.allocPrint(allocator, "({s} {c} {s})", .{ left.text, op, right.text }),
        .value = value,
    };
}

fn expectOperandReg(inst: Instruction, index: usize, expected: u32) !void {
    switch (inst.operands[index]) {
        .reg => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectOperandImmU64(inst: Instruction, index: usize, expected: u64) !void {
    switch (inst.operands[index]) {
        .imm_u64 => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectOperandImmI64(inst: Instruction, index: usize, expected: i64) !void {
    switch (inst.operands[index]) {
        .imm_i64 => |actual| try std.testing.expectEqual(expected, actual),
        else => return error.TestUnexpectedResult,
    }
}

fn expectRawText(inst: Instruction, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, inst.raw_text);
}

test "scanSource preserves line order and classification" {
    const source =
        \\#def SIZE = 16
        \\L_LOOP:
        \\node = alloc 8
    ;
    const lines = try scanSource(std.testing.allocator, source, &.{}, &.{}, &.{});
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqual(@as(u32, 1), lines[0].line_no);
    try std.testing.expectEqual(LineKind.def, lines[0].classified.kind);
    try std.testing.expectEqual(LineKind.label, lines[1].classified.kind);
    try std.testing.expectEqual(LineKind.instruction, lines[2].classified.kind);
    try std.testing.expectEqual(InstructionForm.alloc, lines[2].classified.inst_form.?);
}

test "findFirstForbiddenLine skips native blocks and catches keywords" {
    const source =
        \\$if not scanned$
        \\let x = 1
        \\foo.a.b
    ;
    const hit = findFirstForbiddenLine(source).?;
    try std.testing.expectEqual(@as(u32, 3), hit.line_no);
    try std.testing.expectEqual(forbidden.ForbiddenToken.property_chain, hit.hit.token);
}

test "flatten builds instruction stream with symbol and def tables" {
    const source =
        \\#def SIZE = 8
        \\@entry() -> i32:
        \\L_ENTRY:
        \\node = alloc SIZE
        \\return node
    ;
    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.instructions.len);
    try std.testing.expectEqual(@as(usize, 1), result.function_sigs.len);
    try std.testing.expectEqual(InstKind.func_decl, result.instructions[0].kind);
    try std.testing.expectEqual(InstKind.label, result.instructions[1].kind);
    try std.testing.expectEqual(InstKind.alloc, result.instructions[2].kind);
    try std.testing.expectEqual(InstKind.return_, result.instructions[3].kind);
    try std.testing.expectEqualStrings("8", result.def_dict.get("SIZE").?);
    try std.testing.expectEqualStrings("entry", result.symbols.lookupName(0).?);
    try std.testing.expectEqualStrings("L_ENTRY", result.symbols.lookupName(1).?);
    try std.testing.expectEqualStrings("entry", result.function_sigs[0].name);
    try std.testing.expectEqual(@as(usize, result.instructions.len), result.loc_table.len);
}

test "flatten preserves structured const declarations separately from instructions" {
    const source =
        \\#loc "main.rs":7:3
        \\@const HELLO = utf8:"hello"
        \\@main() -> i32:
        \\L_ENTRY:
        \\return 0
    ;
    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.instructions.len);
    try std.testing.expectEqual(@as(usize, 1), result.const_decls.len);
    try std.testing.expectEqualStrings("HELLO", result.const_decls[0].name);
    try std.testing.expectEqualStrings("utf8:\"hello\"", result.const_decls[0].literal_text);
    try std.testing.expect(result.const_decls[0].upstream_loc != null);
    try std.testing.expectEqualStrings("main.rs", result.const_decls[0].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 7), result.const_decls[0].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 3), result.const_decls[0].upstream_loc.?.col);
    switch (result.const_decls[0].value) {
        .utf8 => |literal| try std.testing.expectEqualStrings("hello", literal.bytes),
        else => return error.TestUnexpectedResult,
    }
}

test "flatten keeps native escape text and extracted register names" {
    const source =
        \\@main() -> i32:
        \\value = alloc 8
        \\$call side(ptr value, i32 7, @glob, %tmp)$
        \\return 0
    ;
    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.instructions.len);
    try std.testing.expectEqual(InstKind.native, result.instructions[2].kind);
    try std.testing.expectEqualStrings("call side(ptr value, i32 7, @glob, %tmp)", result.instructions[2].operands[0].native_text);
    try std.testing.expectEqual(@as(usize, 5), result.instructions[2].native_reg_names.len);
    try std.testing.expectEqualStrings("call", result.instructions[2].native_reg_names[0]);
    try std.testing.expectEqualStrings("side", result.instructions[2].native_reg_names[1]);
    try std.testing.expectEqualStrings("ptr", result.instructions[2].native_reg_names[2]);
    try std.testing.expectEqualStrings("value", result.instructions[2].native_reg_names[3]);
    try std.testing.expectEqualStrings("i32", result.instructions[2].native_reg_names[4]);
}

test "flatten attaches loc hint to the next real instruction only" {
    const source =
        \\#loc "up.rs":12:3
        \\@entry() -> i32:
        \\#loc "up.rs":13:5
        \\L_ENTRY:
        \\#loc "up.rs":14:7
        \\node = alloc 8
        \\return node
    ;
    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.instructions.len);
    try std.testing.expect(result.instructions[0].upstream_loc != null);
    try std.testing.expectEqualStrings("up.rs", result.instructions[0].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 12), result.instructions[0].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 3), result.instructions[0].upstream_loc.?.col);
    try std.testing.expect(result.instructions[1].upstream_loc == null);
    try std.testing.expect(result.instructions[2].upstream_loc != null);
    try std.testing.expectEqualStrings("up.rs", result.instructions[2].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 14), result.instructions[2].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 7), result.instructions[2].upstream_loc.?.col);
    try std.testing.expect(result.instructions[3].upstream_loc == null);
    try std.testing.expectEqual(@as(usize, result.instructions.len), result.loc_table.len);
    try std.testing.expect(result.loc_table[0] == null);
    try std.testing.expect(result.loc_table[1] == null);
    try std.testing.expect(result.loc_table[2] != null);
    try std.testing.expectEqualStrings("up.rs", result.loc_table[2].?.file);
    try std.testing.expect(result.loc_table[3] == null);
    try std.testing.expectEqualStrings("up.rs", result.function_sigs[0].upstream_loc.?.file);
    try std.testing.expectEqual(@as(u32, 12), result.function_sigs[0].upstream_loc.?.line);
    try std.testing.expectEqual(@as(u32, 3), result.function_sigs[0].upstream_loc.?.col);
}

test "flattenFile expands relative @import files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("sa_std/io");
    var iface = try tmp.dir.createFile("sa_std/io/print.sai", .{ .truncate = true });
    try iface.writeAll("@extern sa_print_bytes(&msg: ptr, len: u64) -> void\n");
    iface.close();

    var main_file = try tmp.dir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(
        \\@import "sa_std/io/print.sai"
        \\@main() -> i32:
        \\L_ENTRY:
        \\    return 0
    );
    main_file.close();

    const source = try tmp.dir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tmp.dir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);

    var result = try flattenFile(std.testing.allocator, source_path, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.function_sigs.len);
    try std.testing.expectEqual(FunctionKind.external, result.function_sigs[0].kind);
    try std.testing.expectEqualStrings("sa_print_bytes", result.function_sigs[0].name);
    try std.testing.expectEqual(FunctionKind.normal, result.function_sigs[1].kind);
    try std.testing.expectEqualStrings("main", result.function_sigs[1].name);
}

test "flattenFileWithPackages injects package iface and namespaced layout defs once" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("sa_vendor/github.com/example/pkg");

    var pkg_main = try tmp.dir.createFile("sa_vendor/github.com/example/pkg/index.sa", .{ .truncate = true });
    try pkg_main.writeAll("// package body intentionally empty\n");
    pkg_main.close();

    var pkg_iface = try tmp.dir.createFile("sa_vendor/github.com/example/pkg/index.sai", .{ .truncate = true });
    try pkg_iface.writeAll("@extern pkg_iface() -> i32\n");
    pkg_iface.close();

    var pkg_layout = try tmp.dir.createFile("sa_vendor/github.com/example/pkg/index.sal", .{ .truncate = true });
    try pkg_layout.writeAll(
        \\#version 1
        \\#def Pkg_SIZE = 4
    );
    pkg_layout.close();

    var main_file = try tmp.dir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(
        \\@import "github.com/example/pkg"
        \\
        \\@main() -> i32:
        \\L_ENTRY:
        \\    return 0
    );
    main_file.close();

    const source = try tmp.dir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tmp.dir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);

    const project_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);

    var result = try flattenFileWithPackages(
        std.testing.allocator,
        source_path,
        source,
        .{
            .options = .{ .project_root = project_root },
        },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.function_sigs.len);
    try std.testing.expectEqualStrings("pkg_iface", result.function_sigs[0].name);
    try std.testing.expectEqualStrings("main", result.function_sigs[1].name);
    try std.testing.expectEqual(@as(usize, 1), result.layout_versions.len);
    try std.testing.expectEqual(@as(u64, 1), result.layout_versions[0].version);

    const prefix = try packageNamespacePrefix(std.testing.allocator, "github.com/example/pkg");
    defer std.testing.allocator.free(prefix);
    const namespaced_key = try std.fmt.allocPrint(std.testing.allocator, "{s}.Pkg_SIZE", .{prefix});
    defer std.testing.allocator.free(namespaced_key);
    try std.testing.expectEqualStrings("4", result.def_dict.get(namespaced_key).?);
}

test "flattenFileWithPackages preserves package identity on imported instructions" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("sa_vendor/github.com/example/pkg");

    var pkg_main = try tmp.dir.createFile("sa_vendor/github.com/example/pkg/index.sa", .{ .truncate = true });
    try pkg_main.writeAll(
        \\@main() -> i32:
        \\L_ENTRY:
        \\path = alloc 8
        \\data = alloc 8
        \\value = call @sys_write_file(*path, 4, *data, 4)
        \\!path
        \\!data
        \\return value
    );
    pkg_main.close();

    var main_file = try tmp.dir.createFile("main.sa", .{ .truncate = true });
    try main_file.writeAll(
        \\@import "github.com/example/pkg"
    );
    main_file.close();

    const source = try tmp.dir.readFileAlloc(std.testing.allocator, "main.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tmp.dir.realpathAlloc(std.testing.allocator, "main.sa");
    defer std.testing.allocator.free(source_path);

    const project_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(project_root);

    var resolved = try pkg_resolver.resolveImport(
        std.testing.allocator,
        &.{},
        project_root,
        "github.com/example/pkg",
        .{ .project_root = project_root },
    );
    defer resolved.deinit(std.testing.allocator);
    const expected_hash = resolved.source_sha256 orelse return error.TestUnexpectedResult;

    var result = try flattenFileWithPackages(
        std.testing.allocator,
        source_path,
        source,
        .{
            .options = .{ .project_root = project_root },
        },
    );
    defer result.deinit(std.testing.allocator);

    var saw_pkg_instruction = false;
    var saw_pkg_call = false;
    for (result.instructions) |item| {
        if (item.package_identity) |identity| {
            if (std.mem.eql(u8, identity, "github.com/example/pkg")) {
                saw_pkg_instruction = true;
                try std.testing.expect(item.package_source_sha256 != null);
                const actual_hash = item.package_source_sha256.?;
                try std.testing.expect(std.mem.eql(u8, actual_hash[0..], expected_hash[0..]));
                if (std.mem.eql(u8, item.raw_text, "value = call @sys_write_file(*path, 4, *data, 4)")) {
                    saw_pkg_call = true;
                }
            }
        }
    }
    try std.testing.expect(saw_pkg_instruction);
    try std.testing.expect(saw_pkg_call);
}

test "flattenFile rejects import cycles" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var a_file = try tmp.dir.createFile("a.sa", .{ .truncate = true });
    try a_file.writeAll("@import \"b.sa\"\n");
    a_file.close();

    var b_file = try tmp.dir.createFile("b.sa", .{ .truncate = true });
    try b_file.writeAll("@import \"a.sa\"\n");
    b_file.close();

    const source = try tmp.dir.readFileAlloc(std.testing.allocator, "a.sa", 4096);
    defer std.testing.allocator.free(source);

    const source_path = try tmp.dir.realpathAlloc(std.testing.allocator, "a.sa");
    defer std.testing.allocator.free(source_path);

    try std.testing.expectError(error.ImportCycle, flattenFile(std.testing.allocator, source_path, source));
}

test "macro PBT expands nested macros and repeat bodies deterministically" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6A10);
    const random = prng.random();

    for (0..48) |iter| {
        var program = try buildMacroPbtProgram(std.testing.allocator, random, iter);
        defer program.deinit(std.testing.allocator);

        var result = try flatten(std.testing.allocator, program.source);
        defer result.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), result.function_sigs.len);
        try std.testing.expectEqual(@as(usize, 0), result.const_decls.len);
        try std.testing.expectEqual(@as(usize, 4) + program.count, result.instructions.len);

        const base_id = result.symbols.findId(program.base_name) orelse return error.TestUnexpectedResult;
        const acc_id = result.symbols.findId(program.acc_name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(program.base_name, result.symbols.lookupName(base_id).?);
        try std.testing.expectEqualStrings(program.acc_name, result.symbols.lookupName(acc_id).?);

        try std.testing.expectEqual(InstKind.func_decl, result.instructions[0].kind);
        try std.testing.expectEqual(InstKind.alloc, result.instructions[1].kind);
        try std.testing.expectEqual(InstKind.op, result.instructions[2].kind);
        try std.testing.expectEqual(common_instruction.OpKind.add, result.instructions[2].op_kind.?);
        try std.testing.expectEqual(InstKind.return_, result.instructions[result.instructions.len - 1].kind);

        var line_buf: [128]u8 = undefined;
        var tmp_buf: [32]u8 = undefined;

        const alloc_line = try std.fmt.bufPrint(&line_buf, "    {s} = alloc {d}", .{ program.base_name, program.alloc_size });
        try expectRawText(result.instructions[1], alloc_line);
        try expectOperandReg(result.instructions[1], 0, base_id);
        try expectOperandImmU64(result.instructions[1], 1, program.alloc_size);

        const seed_line = try std.fmt.bufPrint(&line_buf, "    {s} = add {s}, 0", .{ program.acc_name, program.base_name });
        try expectRawText(result.instructions[2], seed_line);
        try expectOperandReg(result.instructions[2], 0, acc_id);
        try expectOperandReg(result.instructions[2], 1, base_id);
        try expectOperandImmI64(result.instructions[2], 2, 0);

        for (0..program.count) |idx| {
            const tmp_name = try std.fmt.bufPrint(&tmp_buf, "tmp_{d}", .{idx});
            const tmp_id = result.symbols.findId(tmp_name) orelse return error.TestUnexpectedResult;
            const inst = result.instructions[3 + idx];
            const expected_text = try std.fmt.bufPrint(&line_buf, "        {s} = add {s}, {d}", .{ tmp_name, program.acc_name, idx });
            try expectRawText(inst, expected_text);
            try std.testing.expectEqual(InstKind.op, inst.kind);
            try std.testing.expectEqual(common_instruction.OpKind.add, inst.op_kind.?);
            try expectOperandReg(inst, 0, tmp_id);
            try expectOperandReg(inst, 1, acc_id);
            try expectOperandImmI64(inst, 2, @intCast(idx));
        }

        const return_line = try std.fmt.bufPrint(&line_buf, "    return {s}", .{program.acc_name});
        try expectRawText(result.instructions[result.instructions.len - 1], return_line);
        try expectOperandReg(result.instructions[result.instructions.len - 1], 0, acc_id);
    }
}

test "variadic macro parameters consume remaining arguments" {
    const source =
        \\[MACRO] CALL_SUM %dst, %args...
        \\    %dst = call @sum(%args)
        \\[END_MACRO]
        \\[MACRO] ZERO_OK %dst, %args...
        \\    %dst = add 1, 0
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    EXPAND CALL_SUM total, 1, 2, 3
        \\    EXPAND ZERO_OK empty
        \\    return 0
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), result.instructions.len);
    try std.testing.expectEqual(InstKind.func_decl, result.instructions[0].kind);
    try std.testing.expectEqual(InstKind.call, result.instructions[1].kind);
    try expectRawText(result.instructions[1], "    total = call @sum(1, 2, 3)");
    try std.testing.expectEqual(InstKind.op, result.instructions[2].kind);
    try expectRawText(result.instructions[2], "    empty = add 1, 0");
    try std.testing.expectEqual(InstKind.return_, result.instructions[3].kind);
}

test "variadic macro parameter must be last" {
    const source =
        \\[MACRO] BAD %args..., %tail
        \\    %tail = add 1, 0
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    return 0
    ;

    try std.testing.expectError(error.InvalidMacroInvocation, flatten(std.testing.allocator, source));
}

test "macro-time conditionals select then else and nested branches" {
    const source =
        \\[MACRO] PICK %dst, %flag
        \\[IF %flag]
        \\    %dst = add 10, 1
        \\[ELSE]
        \\    %dst = add 20, 2
        \\[END_IF]
        \\[END_MACRO]
        \\[MACRO] NEST %dst, %outer, %inner
        \\[IF %outer]
        \\[IF %inner]
        \\    %dst = add 1, 1
        \\[ELSE]
        \\    %dst = add 2, 2
        \\[END_IF]
        \\[END_IF]
        \\[END_MACRO]
        \\[MACRO] MAYBE %dst, %flag
        \\[IF %flag]
        \\    %dst = add 9, 9
        \\[END_IF]
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    EXPAND PICK a, true
        \\    EXPAND PICK b, false
        \\    EXPAND NEST c, 1, 0
        \\    EXPAND MAYBE d, 0
        \\    return 0
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 5), result.instructions.len);
    try expectRawText(result.instructions[1], "    a = add 10, 1");
    try expectRawText(result.instructions[2], "    b = add 20, 2");
    try expectRawText(result.instructions[3], "    c = add 2, 2");
    try std.testing.expectEqual(InstKind.return_, result.instructions[4].kind);
}

test "macro-time conditional rejects invalid condition values" {
    const source =
        \\[MACRO] BAD %flag
        \\[IF %flag]
        \\    x = add 1, 0
        \\[END_IF]
        \\[END_MACRO]
        \\
        \\@main() -> i32:
        \\    EXPAND BAD maybe
        \\    return 0
    ;

    try std.testing.expectError(error.InvalidMacroInvocation, flatten(std.testing.allocator, source));
}

test "macro PBT rejects invalid definitions and invocations" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6A11);
    const random = prng.random();

    for (0..36) |iter| {
        const case_id = random.intRangeLessThan(u8, 0, 6);
        const ghost_name = try std.fmt.allocPrint(std.testing.allocator, "ghost_{d}_{d}", .{ iter, random.intRangeAtMost(u16, 0, 9999) });
        defer std.testing.allocator.free(ghost_name);

        const source = switch (case_id) {
            0 => try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\EXPAND {s} value
                \\return 0
            , .{ghost_name}),
            1 => try std.fmt.allocPrint(std.testing.allocator,
                \\[MACRO] SINGLE %x
                \\    %x = add 1, 0
                \\[END_MACRO]
                \\
                \\@main() -> i32:
                \\    EXPAND SINGLE value, extra
                \\    return 0
            , .{}),
            2 => try std.fmt.allocPrint(std.testing.allocator,
                \\[MACRO] DUP %x
                \\    %x = add 1, 0
                \\[END_MACRO]
                \\[MACRO] DUP %x
                \\    %x = add 2, 0
                \\[END_MACRO]
                \\
                \\@main() -> i32:
                \\    return 0
            , .{}),
            3 => try std.fmt.allocPrint(std.testing.allocator,
                \\[MACRO] OPEN %x
                \\    %x = add 1, 0
                \\
                \\@main() -> i32:
                \\    return 0
            , .{}),
            4 => try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\[REP 2]
                \\    return 0
                \\return 0
            , .{}),
            5 => try std.fmt.allocPrint(std.testing.allocator,
                \\[MACRO] LOOP %x
                \\    EXPAND LOOP %x
                \\[END_MACRO]
                \\
                \\@main() -> i32:
                \\    EXPAND LOOP value
                \\    return 0
            , .{}),
            else => unreachable,
        };
        defer std.testing.allocator.free(source);

        const expected_error = switch (case_id) {
            0, 1 => error.InvalidMacroInvocation,
            2 => error.DuplicateDef,
            3 => error.UnbalancedMacro,
            4 => error.UnbalancedRep,
            5 => error.MacroRecursionLimit,
            else => unreachable,
        };
        try std.testing.expectError(expected_error, flatten(std.testing.allocator, source));
    }
}

test "def dict PBT folds random arithmetic expressions through flatten" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6A20);
    const random = prng.random();

    for (0..48) |iter| {
        var base_expr = try buildArithmeticExpr(std.testing.allocator, random, 3);
        defer base_expr.deinit(std.testing.allocator);

        const delta = @as(i64, @intCast(random.intRangeAtMost(i32, -3, 6)));
        const size_value = base_expr.value + delta;

        const tmp_name = try std.fmt.allocPrint(std.testing.allocator, "tmp_{d}", .{iter});
        defer std.testing.allocator.free(tmp_name);

        var source = std.ArrayList(u8).init(std.testing.allocator);
        errdefer source.deinit();
        const writer = source.writer();
        try writer.writeAll("#def BASE = ");
        try writer.writeAll(base_expr.text);
        try writer.writeByte('\n');
        try writer.print("#def SIZE = BASE + {d}\n", .{delta});
        try writer.writeAll("@main() -> i32:\n");
        try writer.print("{s} = add SIZE, 1\n", .{tmp_name});
        try writer.print("return {s}\n", .{tmp_name});

        const source_text = try source.toOwnedSlice();
        defer std.testing.allocator.free(source_text);

        var result = try flatten(std.testing.allocator, source_text);
        defer result.deinit(std.testing.allocator);

        var base_buf: [32]u8 = undefined;
        const base_text = try std.fmt.bufPrint(&base_buf, "{d}", .{base_expr.value});
        try std.testing.expectEqualStrings(base_text, result.def_dict.get("BASE").?);

        var size_buf: [32]u8 = undefined;
        const size_text = try std.fmt.bufPrint(&size_buf, "{d}", .{size_value});
        try std.testing.expectEqualStrings(size_text, result.def_dict.get("SIZE").?);

        try std.testing.expectEqual(@as(usize, 3), result.instructions.len);
        try std.testing.expectEqual(InstKind.func_decl, result.instructions[0].kind);
        try std.testing.expectEqual(InstKind.op, result.instructions[1].kind);
        try std.testing.expectEqual(common_instruction.OpKind.add, result.instructions[1].op_kind.?);
        try expectOperandImmI64(result.instructions[1], 1, size_value);
        try expectOperandImmI64(result.instructions[1], 2, 1);
        try std.testing.expectEqual(InstKind.return_, result.instructions[2].kind);
    }
}

test "forbidden syntax PBT rejects random forbidden lines through flatten" {
    const ForbiddenCase = struct {
        text: []const u8,
        token: forbidden.ForbiddenToken,
    };

    const cases = [_]ForbiddenCase{
        .{ .text = "if x = 1", .token = .keyword_if },
        .{ .text = "else x = 1", .token = .keyword_else },
        .{ .text = "while x = 1", .token = .keyword_while },
        .{ .text = "for x = 1", .token = .keyword_for },
        .{ .text = "x = { y }", .token = .brace_open },
        .{ .text = "x = }", .token = .brace_close },
        .{ .text = "x = a.b.c", .token = .property_chain },
    };

    var prng = std.Random.DefaultPrng.init(0x5A5A_6A21);
    const random = prng.random();

    for (0..48) |iter| {
        const case = cases[random.intRangeLessThan(usize, 0, cases.len)];
        try std.testing.expectEqual(case.token, forbidden.findForbiddenSyntax(case.text).?.token);

        const forbidden_at_tail = (iter & 1) == 0;
        const source = if (forbidden_at_tail) blk: {
            break :blk try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\value = alloc 8
                \\{s}
                \\return 0
            , .{case.text});
        } else blk: {
            break :blk try std.fmt.allocPrint(std.testing.allocator,
                \\@main() -> i32:
                \\{s}
                \\value = alloc 8
                \\return 0
            , .{case.text});
        };
        defer std.testing.allocator.free(source);

        const expected_line_no: u32 = if (forbidden_at_tail) 3 else 2;
        const found = findFirstForbiddenLine(source).?;
        try std.testing.expectEqual(expected_line_no, found.line_no);
        try std.testing.expectEqual(case.token, found.hit.token);
        try std.testing.expectError(error.ForbiddenSyntax, flatten(std.testing.allocator, source));
    }
}

test "PRINT! and FORMAT! macro static expansion" {
    const source =
        \\@main() -> i32:
        \\EXPAND PRINT! "Hello, world!"
        \\EXPAND PRINT! "Value: {}", %val
        \\EXPAND FORMAT! %res, "A: {}, B: {}", %val1, %val2
        \\return 0
    ;

    var result = try flatten(std.testing.allocator, source);
    defer result.deinit(std.testing.allocator);

    // Let's assert that we have registered some const_decls for the literal segments
    try std.testing.expect(result.const_decls.len >= 3);

    // Let's verify that the literal contents match
    var found_hello = false;
    var found_value = false;
    var found_a = false;
    for (result.const_decls) |decl| {
        if (std.mem.eql(u8, decl.name, "__PRINT_LIT_2_0")) {
            try std.testing.expectEqualStrings("Hello, world!", decl.value.utf8.bytes);
            found_hello = true;
        }
        if (std.mem.indexOf(u8, decl.name, "__PRINT_LIT_3_") != null) {
            try std.testing.expectEqualStrings("Value: ", decl.value.utf8.bytes);
            found_value = true;
        }
        if (std.mem.indexOf(u8, decl.name, "__PRINT_LIT_4_") != null) {
            if (std.mem.eql(u8, decl.value.utf8.bytes, "A: ")) {
                found_a = true;
            }
        }
    }
    try std.testing.expect(found_hello);
    try std.testing.expect(found_value);
    try std.testing.expect(found_a);

    // Verify some instructions generated by the macros exist
    var found_sys_print = false;
    for (result.instructions) |inst| {
        if (inst.kind == .call) {
            if (inst.operands[0] == .text) {
                if (std.mem.startsWith(u8, inst.operands[0].text, "@sys_print")) {
                    found_sys_print = true;
                }
            }
        }
    }
    try std.testing.expect(found_sys_print);
}
