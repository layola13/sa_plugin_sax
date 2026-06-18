const std = @import("std");

const call = @import("referee/call.zig");
const referee = @import("referee.zig");
const emit_options = @import("emit_options.zig");
const flattener = @import("flattener.zig");
const inst = @import("common/instruction.zig");
const atomic = @import("common/atomic.zig");
const sig = @import("common/signature.zig");
const const_decl = @import("common/const_decl.zig");
const upstream = @import("common/upstream_loc.zig");

extern fn sa_llvmc_free(ptr: ?*anyopaque) callconv(.C) void;
extern fn sa_llvmc_make_minimal_module_bitcode(out_bytes: *?[*]u8, out_len: *usize, out_error: *?[*:0]u8) callconv(.C) i32;
extern fn sa_llvmc_emit_module_bitcode(module: *const CModule, opt_level: c_int, out_bytes: *?[*]u8, out_len: *usize, out_error: *?[*:0]u8) callconv(.C) i32;
extern fn sa_llvmc_emit_module_object(module: *const CModule, out_path: [*:0]const u8, opt_level: c_int, out_error: *?[*:0]u8) callconv(.C) i32;
extern fn sa_llvmc_emit_module_artifacts(module: *const CModule, out_bitcode_path: [*:0]const u8, out_object_path: [*:0]const u8, opt_level: c_int, out_error: *?[*:0]u8) callconv(.C) i32;

pub const LlvmcError = error{ Failed, InvalidOperand, UnsupportedType, UnknownFunction, UnsupportedInstruction };
pub const EmitOptions = emit_options.EmitOptions;

const CType = enum(c_int) { void = 0, i1 = 1, i8 = 2, i16 = 3, i32 = 4, i64 = 5, f32 = 6, f64 = 7, ptr = 8, u8 = 9, u16 = 10, u32 = 11, u64 = 12 };
const CFuncKind = enum(c_int) { normal = 0, external = 1, exported = 2, test_func = 3 };
const COp = enum(c_int) { none = 0, label = 1, alloc = 2, stack_alloc = 3, load = 4, store = 5, op = 6, ptr_add = 7, jmp = 8, br = 9, call = 10, ret = 11, panic = 12, panic_msg = 13, atomic_load = 14, atomic_store = 15, atomic_rmw = 16, cmpxchg = 17, fence = 18, try_ = 19, call_indirect = 20, assign = 21 };
const COperandKind = enum(c_int) { none = 0, reg = 1, imm_i64 = 2, imm_u64 = 3, const_ptr = 4, imm_f64 = 5 };
const CBinaryOp = enum(c_int) { add = 0, sub = 1, mul = 2, sdiv = 3, udiv = 4, srem = 5, urem = 6, band = 7, bor = 8, xor = 9, shl = 10, lshr = 11, ashr = 12, eq = 13, ne = 14, slt = 15, sle = 16, sgt = 17, sge = 18, ult = 19, ule = 20, ugt = 21, uge = 22, fadd = 23, fsub = 24, fmul = 25, fdiv = 26, fcmp_eq = 27, fcmp_ne = 28, fcmp_lt = 29, fcmp_le = 30, fcmp_gt = 31, fcmp_ge = 32 };
const CAtomicOrdering = enum(c_int) { relaxed = 0, acquire = 1, release = 2, acq_rel = 3, seq_cst = 4 };
const CAtomicRmwOp = enum(c_int) { add = 0, sub = 1, band = 2, bor = 3, xor = 4, xchg = 5, min = 6, max = 7, umin = 8, umax = 9 };

const CConst = extern struct { name: [*:0]const u8, data: [*]const u8, len: usize };
const CVTable = extern struct { name: [*:0]const u8, funcs: [*]const [*:0]const u8, func_count: usize };
const CParam = extern struct { name: [*:0]const u8, ty: CType, slot: u32 };
const CDebugLoc = extern struct { line: u32, col: u32 };
const CDebugVar = extern struct { name: [*:0]const u8, ty: CType, slot: u32, is_param: bool, line: u32, col: u32 };
const COperand = extern struct { kind: COperandKind, reg: u32, i64_value: i64, u64_value: u64, f64_value: f64, ty: CType, name: ?[*:0]const u8 };
const CInstruction = extern struct {
    op: COp,
    dst: u32,
    operand0: COperand,
    operand1: COperand,
    operand2: COperand,
    ty: CType,
    binary_op: CBinaryOp,
    label: ?[*:0]const u8,
    false_label: ?[*:0]const u8,
    callee: ?[*:0]const u8,
    args: [*]const COperand,
    arg_count: usize,
    indirect_param_tys: [*]const CType,
    indirect_param_count: usize,
    has_dst: bool,
    atomic_ordering: CAtomicOrdering,
    atomic_second_ordering: CAtomicOrdering,
    atomic_rmw_op: CAtomicRmwOp,
    return_fallible: bool,
    indirect_sig_index: u32,
};
const CFunction = extern struct {
    name: [*:0]const u8,
    kind: CFuncKind,
    ret_ty: CType,
    return_fallible: bool,
    params: [*]const CParam,
    param_count: usize,
    instructions: [*]const CInstruction,
    instruction_count: usize,
    source_file: ?[*:0]const u8,
    source_dir: ?[*:0]const u8,
    entry_line: u32,
    entry_col: u32,
    debug_locs: [*]const CDebugLoc,
    debug_loc_count: usize,
    debug_vars: [*]const CDebugVar,
    debug_var_count: usize,
    emit_main_wrapper: bool,
};
const CModule = extern struct {
    size_bits: u16,
    wasm_compat: bool,
    test_mode: bool,
    debug: bool,
    is_cgu: bool,
    source_file: ?[*:0]const u8,
    source_dir: ?[*:0]const u8,
    consts: [*]const CConst,
    const_count: usize,
    vtables: [*]const CVTable,
    vtable_count: usize,
    functions: [*]const CFunction,
    function_count: usize,
};

fn takeOwnedBitcode(allocator: std.mem.Allocator, bytes: *?[*]u8, len: *usize) ![]u8 {
    const ptr = bytes.* orelse return error.Failed;
    const out = try allocator.dupe(u8, ptr[0..len.*]);
    sa_llvmc_free(ptr);
    bytes.* = null;
    len.* = 0;
    return out;
}

fn cType(ty: sig.PrimType) !CType {
    return switch (ty) {
        .void => .void,
        .i1 => .i1,
        .i8 => .i8,
        .u8 => .u8,
        .i16 => .i16,
        .u16 => .u16,
        .i32, .blob_handle => .i32,
        .u32 => .u32,
        .i64 => .i64,
        .u64 => .u64,
        .f32 => .f32,
        .f64 => .f64,
        .ptr => .ptr,
        else => error.UnsupportedType,
    };
}

fn valueTypeForPrefix(prefix: inst.CapPrefix, ty: sig.PrimType) sig.PrimType {
    return switch (prefix) {
        .borrow, .raw => .ptr,
        .move, .by_value => ty,
    };
}

fn isRawQuotedStringArg(arg: call.ParsedArg) bool {
    return arg.prefix == .raw and arg.text.len >= 2 and arg.text[0] == '"' and arg.text[arg.text.len - 1] == '"';
}

fn parseHexDigitPair(text: []const u8) !u8 {
    if (text.len != 2) return error.InvalidOperand;
    const hi = std.fmt.charToDigit(text[0], 16) catch return error.InvalidOperand;
    const lo = std.fmt.charToDigit(text[1], 16) catch return error.InvalidOperand;
    return @as(u8, @intCast((hi << 4) | lo));
}

fn decodeQuotedBytes(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.InvalidOperand;

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var i: usize = 1;
    while (i < raw.len - 1) {
        const c = raw[i];
        if (c != '\\') {
            try out.append(c);
            i += 1;
            continue;
        }

        if (i + 1 >= raw.len - 1) return error.InvalidOperand;
        switch (raw[i + 1]) {
            '\\' => {
                try out.append('\\');
                i += 2;
            },
            '"' => {
                try out.append('"');
                i += 2;
            },
            'n' => {
                try out.append('\n');
                i += 2;
            },
            'r' => {
                try out.append('\r');
                i += 2;
            },
            't' => {
                try out.append('\t');
                i += 2;
            },
            '0' => {
                try out.append(0);
                i += 2;
            },
            'x' => {
                if (i + 3 >= raw.len - 1) return error.InvalidOperand;
                try out.append(try parseHexDigitPair(raw[i + 2 .. i + 4]));
                i += 4;
            },
            else => return error.InvalidOperand,
        }
    }

    return try out.toOwnedSlice();
}

fn returnTypeForSig(return_cap: ?inst.CapPrefix, return_ty: sig.PrimType) sig.PrimType {
    if (return_ty == .void) return .void;
    return switch (return_cap orelse .by_value) {
        .raw, .borrow => .ptr,
        .move, .by_value => return_ty,
    };
}

fn emittedFunctionName(fsig: sig.FunctionSig) []const u8 {
    if (fsig.kind == .normal and fsig.params.len == 0 and std.mem.eql(u8, fsig.name, "main")) {
        return "saasm_main";
    }
    if (fsig.llvm_name) |name| return name;
    return fsig.name;
}

fn sourceFileName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn sourceDirName(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn debugLocForInstruction(item: inst.Instruction, table_loc: ?upstream.UpstreamLoc, fallback: CDebugLoc) CDebugLoc {
    if (table_loc) |actual| return .{ .line = actual.line, .col = actual.col };
    if (item.upstream_loc) |actual| return .{ .line = actual.line, .col = actual.col };
    if (item.source_line != 0) return .{ .line = item.source_line, .col = 1 };
    return fallback;
}

fn makeSlotFallbackName(allocator: std.mem.Allocator, slot: usize) ![*:0]const u8 {
    const text = try std.fmt.allocPrintZ(allocator, "slot_{d}", .{slot});
    return text.ptr;
}

fn buildDebugVars(allocator: std.mem.Allocator, symbols: anytype, fsig: sig.FunctionSig, entry_loc: CDebugLoc) ![]CDebugVar {
    if (fsig.reg_ids.len == 0) return &.{};
    const vars = try allocator.alloc(CDebugVar, fsig.reg_ids.len);
    for (fsig.reg_ids, 0..) |reg_id, slot| {
        const raw_name = symbols.lookupName(reg_id);
        const name = if (raw_name) |value| (try allocator.dupeZ(u8, value)).ptr else try makeSlotFallbackName(allocator, slot);
        vars[slot] = .{
            .name = name,
            .ty = .i64,
            .slot = @intCast(slot),
            .is_param = false,
            .line = entry_loc.line,
            .col = entry_loc.col,
        };
    }
    for (fsig.params, 0..) |param, pidx| {
        if (pidx >= fsig.param_ids.len) continue;
        const slot = fsig.slotOf(fsig.param_ids[pidx]) orelse continue;
        if (slot >= vars.len) continue;
        vars[slot].ty = try cType(valueTypeForPrefix(param.cap, param.ty));
        vars[slot].is_param = true;
    }
    return vars;
}

fn constBytesLen(value: const_decl.ConstValue) !usize {
    return switch (value) {
        .hex, .utf8 => |literal| literal.bytes.len,
        .repeat => |literal| @intCast(literal.repeat_count orelse return error.InvalidOperand),
        .struct_ => |literal| blk: {
            var total: usize = 0;
            for (literal.fields) |field| {
                const len = try constBytesLen(field.value);
                if (len != field.size) return error.InvalidOperand;
                total = std.math.add(usize, total, len) catch return error.InvalidOperand;
            }
            break :blk total;
        },
        else => error.UnsupportedType,
    };
}

fn fillConstBytes(out: []u8, value: const_decl.ConstValue) !void {
    switch (value) {
        .hex, .utf8 => |literal| @memcpy(out, literal.bytes),
        .repeat => |literal| @memset(out, literal.repeat_byte orelse 0),
        .struct_ => |literal| {
            var cursor: usize = 0;
            for (literal.fields) |field| {
                const len = try constBytesLen(field.value);
                if (len != field.size or cursor + len > out.len) return error.InvalidOperand;
                try fillConstBytes(out[cursor .. cursor + len], field.value);
                cursor += len;
            }
            if (cursor != out.len) return error.InvalidOperand;
        },
        else => return error.UnsupportedType,
    }
}

fn collectAnonStringConsts(
    allocator: std.mem.Allocator,
    annotated: []const referee.AnnotatedInstruction,
    anon_string_names: *std.StringHashMap([*:0]const u8),
    c_consts: *std.ArrayList(CConst),
) !void {
    var anon_idx: usize = c_consts.items.len;
    for (annotated) |item| {
        switch (item.base.kind) {
            .call, .call_indirect, .panic, .panic_msg => {},
            else => continue,
        }

        var parsed = call.parseCall(allocator, item.base.raw_text) catch |err| switch (err) {
            error.InvalidCallSyntax => continue,
            else => return err,
        };
        defer parsed.deinit(allocator);

        for (parsed.args) |arg| {
            if (!isRawQuotedStringArg(arg)) continue;
            if (anon_string_names.contains(arg.text)) continue;

            const bytes = try decodeQuotedBytes(allocator, arg.text);
            defer allocator.free(bytes);
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidOperand;

            const raw_key = try allocator.dupe(u8, arg.text);
            errdefer allocator.free(raw_key);
            const name = try std.fmt.allocPrintZ(allocator, "__sa_anon_str_{d}", .{anon_idx});
            const data = try allocator.dupe(u8, bytes);

            try c_consts.append(.{ .name = name.ptr, .data = data.ptr, .len = data.len });
            try anon_string_names.put(raw_key, name.ptr);
            anon_idx += 1;
        }
    }
}

const BuildState = struct {
    allocator: std.mem.Allocator,
    symbols: *const @import("flattener/symbol.zig").SymbolTable,
    fsig: sig.FunctionSig,
    const_names: std.StringHashMap(void),
    anon_string_names: *const std.StringHashMap([*:0]const u8),
    const_decls: []const const_decl.ConstDecl,
    function_sigs: []const sig.FunctionSig,
    function_sig_index: *const std.StringHashMap(usize),

    fn init(
        allocator: std.mem.Allocator,
        symbols: *const @import("flattener/symbol.zig").SymbolTable,
        fsig: sig.FunctionSig,
        const_decls: []const const_decl.ConstDecl,
        function_sigs: []const sig.FunctionSig,
        function_sig_index: *const std.StringHashMap(usize),
        anon_string_names: *const std.StringHashMap([*:0]const u8),
    ) !BuildState {
        var const_names = std.StringHashMap(void).init(allocator);
        errdefer const_names.deinit();
        for (const_decls) |decl| try const_names.put(decl.name, {});
        return .{ .allocator = allocator, .symbols = symbols, .fsig = fsig, .const_names = const_names, .anon_string_names = anon_string_names, .const_decls = const_decls, .function_sigs = function_sigs, .function_sig_index = function_sig_index };
    }

    fn deinit(self: *BuildState) void {
        self.const_names.deinit();
    }

    fn calleeSig(self: *BuildState, name: []const u8) ?sig.FunctionSig {
        const idx = self.function_sig_index.get(name) orelse return null;
        return self.function_sigs[idx];
    }

    fn operand(self: *BuildState, op: inst.Operand) !COperand {
        return switch (op) {
            .reg => |slot| .{ .kind = .reg, .reg = slot, .i64_value = 0, .u64_value = 0, .f64_value = 0, .ty = .i64, .name = null },
            .imm_i64 => |v| .{ .kind = .imm_i64, .reg = 0, .i64_value = v, .u64_value = 0, .f64_value = 0, .ty = .i64, .name = null },
            .imm_int => |v| .{ .kind = .imm_i64, .reg = 0, .i64_value = v, .u64_value = 0, .f64_value = 0, .ty = .i64, .name = null },
            .imm_u64 => |v| .{ .kind = .imm_u64, .reg = 0, .i64_value = 0, .u64_value = v, .f64_value = 0, .ty = .i64, .name = null },
            .imm_float => |v| .{ .kind = .imm_f64, .reg = 0, .i64_value = 0, .u64_value = 0, .f64_value = v, .ty = .f64, .name = null },
            .text => |text| try self.textOperand(text),
            else => error.InvalidOperand,
        };
    }

    fn callArgOperand(self: *BuildState, arg: call.ParsedArg) !COperand {
        if (isRawQuotedStringArg(arg)) {
            const name = self.anon_string_names.get(arg.text) orelse return error.InvalidOperand;
            return .{ .kind = .const_ptr, .reg = 0, .i64_value = 0, .u64_value = 0, .f64_value = 0, .ty = .ptr, .name = name };
        }
        return try self.textOperand(arg.text);
    }

    fn textOperand(self: *BuildState, raw: []const u8) !COperand {
        var text = std.mem.trim(u8, raw, " \t");
        if (text.len == 0) return error.InvalidOperand;
        if (text[0] == '&' or text[0] == '*' or text[0] == '^') text = std.mem.trim(u8, text[1..], " \t");
        const explicit_ty: ?CType = if (std.mem.lastIndexOf(u8, text, " as ")) |idx| blk: {
            const ty_text = std.mem.trim(u8, text[idx + 4 ..], " \t\r");
            text = std.mem.trim(u8, text[0..idx], " \t\r");
            break :blk if (std.mem.eql(u8, ty_text, "ptr"))
                .ptr
            else if (std.mem.eql(u8, ty_text, "i1"))
                .i1
            else if (std.mem.eql(u8, ty_text, "i8"))
                .i8
            else if (std.mem.eql(u8, ty_text, "u8"))
                .u8
            else if (std.mem.eql(u8, ty_text, "i16"))
                .i16
            else if (std.mem.eql(u8, ty_text, "u16"))
                .u16
            else if (std.mem.eql(u8, ty_text, "i32"))
                .i32
            else if (std.mem.eql(u8, ty_text, "u32"))
                .u32
            else if (std.mem.eql(u8, ty_text, "i64"))
                .i64
            else if (std.mem.eql(u8, ty_text, "u64"))
                .u64
            else if (std.mem.eql(u8, ty_text, "f32"))
                .f32
            else if (std.mem.eql(u8, ty_text, "f64"))
                .f64
            else
                null;
        } else null;
        if (std.fmt.parseInt(i64, text, 10)) |v| {
            return .{ .kind = .imm_i64, .reg = 0, .i64_value = v, .u64_value = 0, .f64_value = 0, .ty = explicit_ty orelse .i64, .name = null };
        } else |_| {}
        if (std.fmt.parseFloat(f64, text)) |v| {
            return .{ .kind = .imm_f64, .reg = 0, .i64_value = 0, .u64_value = 0, .f64_value = v, .ty = explicit_ty orelse .f64, .name = null };
        } else |_| {}
        if (self.const_names.contains(text)) {
            const z = try self.allocator.dupeZ(u8, text);
            return .{ .kind = .const_ptr, .reg = 0, .i64_value = 0, .u64_value = 0, .f64_value = 0, .ty = .ptr, .name = z.ptr };
        }
        if (self.symbols.findId(text)) |id| {
            if (self.fsig.slotOf(id)) |slot| {
                return .{ .kind = .reg, .reg = slot, .i64_value = 0, .u64_value = 0, .f64_value = 0, .ty = .i64, .name = null };
            }
        }
        return error.InvalidOperand;
    }
};

fn labelNameZ(allocator: std.mem.Allocator, symbols: anytype, operand: inst.Operand) ![*:0]const u8 {
    const id = switch (operand) {
        .label => |v| v,
        else => return error.InvalidOperand,
    };
    const name = symbols.lookupName(id) orelse return error.InvalidOperand;
    return (try allocator.dupeZ(u8, name)).ptr;
}

fn binaryOp(kind: inst.OpKind) !CBinaryOp {
    return switch (kind) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .sdiv, .div => .sdiv,
        .udiv => .udiv,
        .srem, .rem => .srem,
        .urem => .urem,
        .@"and" => .band,
        .@"or" => .bor,
        .xor => .xor,
        .shl => .shl,
        .lshr => .lshr,
        .ashr, .shr => .ashr,
        .eq => .eq,
        .ne => .ne,
        .slt, .lt => .slt,
        .sle => .sle,
        .sgt, .gt => .sgt,
        .sge => .sge,
        .ult => .ult,
        .ule => .ule,
        .ugt => .ugt,
        .uge => .uge,
        .fadd => .fadd,
        .fsub, .fneg => .fsub,
        .fmul => .fmul,
        .fdiv => .fdiv,
        .fcmp_eq => .fcmp_eq,
        .fcmp_ne => .fcmp_ne,
        .fcmp_lt => .fcmp_lt,
        .fcmp_le => .fcmp_le,
        .fcmp_gt => .fcmp_gt,
        .fcmp_ge => .fcmp_ge,
        else => error.UnsupportedInstruction,
    };
}

fn atomicOrdering(ordering: ?atomic.AtomicOrdering) CAtomicOrdering {
    return switch (ordering orelse .seq_cst) {
        .relaxed => .relaxed,
        .acquire => .acquire,
        .release => .release,
        .acq_rel => .acq_rel,
        .seq_cst => .seq_cst,
    };
}

fn atomicRmwOp(op: ?atomic.AtomicRmwOp) !CAtomicRmwOp {
    return switch (op orelse return error.InvalidOperand) {
        .add => .add,
        .sub => .sub,
        .@"and" => .band,
        .@"or" => .bor,
        .xor => .xor,
        .xchg => .xchg,
        .min => .min,
        .max => .max,
        .umin => .umin,
        .umax => .umax,
    };
}

fn atomicValueType(base: inst.Instruction, fallback: sig.PrimType) sig.PrimType {
    if (base.atomic_value_ty) |tag| {
        return sig.primTypeFromTag(tag) orelse fallback;
    }
    return fallback;
}

fn findFunctionSigIndex(sigs: []const sig.FunctionSig, name: []const u8) ?usize {
    for (sigs, 0..) |candidate, idx| {
        if (std.mem.eql(u8, candidate.name, name)) return idx;
        if (candidate.llvm_name) |llvm_name| {
            if (std.mem.eql(u8, llvm_name, name)) return idx;
        }
        if (std.mem.eql(u8, emittedFunctionName(candidate), name)) return idx;
    }
    return null;
}

fn putFunctionSigAlias(index: *std.StringHashMap(usize), name: []const u8, sig_idx: usize) !void {
    const entry = try index.getOrPut(name);
    if (!entry.found_existing) entry.value_ptr.* = sig_idx;
}

fn buildFunctionSigIndex(allocator: std.mem.Allocator, sigs: []const sig.FunctionSig) !std.StringHashMap(usize) {
    var index = std.StringHashMap(usize).init(allocator);
    errdefer index.deinit();
    const max_aliases = std.math.mul(usize, sigs.len, 3) catch sigs.len;
    try index.ensureTotalCapacity(@intCast(max_aliases));
    for (sigs, 0..) |candidate, idx| {
        try putFunctionSigAlias(&index, candidate.name, idx);
        if (candidate.llvm_name) |llvm_name| try putFunctionSigAlias(&index, llvm_name, idx);
        try putFunctionSigAlias(&index, emittedFunctionName(candidate), idx);
    }
    return index;
}

fn markReachableFunctionByName(reachable: *std.StringHashMap(void), sigs: []const sig.FunctionSig, sig_index: *const std.StringHashMap(usize), name: []const u8) !bool {
    const idx = sig_index.get(name) orelse return false;
    const canonical_name = sigs[idx].name;
    if (reachable.contains(canonical_name)) return false;
    try reachable.put(canonical_name, {});
    return true;
}

fn collectBodyDirectCallees(allocator: std.mem.Allocator, verified: anytype, sig_index: *const std.StringHashMap(usize), start_idx: usize, end_idx: usize, reachable: *std.StringHashMap(void)) !bool {
    var changed = false;
    for (verified.annotated[start_idx..end_idx]) |body_item| {
        const base = body_item.base;
        if (base.kind != .call and base.kind != .call_indirect) continue;

        var parsed = call.parseCall(allocator, base.raw_text) catch |err| switch (err) {
            error.InvalidCallSyntax => continue,
            else => return err,
        };
        defer parsed.deinit(allocator);

        if (parsed.is_indirect) continue;
        changed = (try markReachableFunctionByName(reachable, verified.function_sigs, sig_index, parsed.callee)) or changed;
    }
    return changed;
}

fn collectNormalBuildReachability(allocator: std.mem.Allocator, verified: anytype, sig_index_by_name: *const std.StringHashMap(usize), reachable: *std.StringHashMap(void)) !void {
    for (verified.const_decls) |decl| {
        switch (decl.value) {
            .vtable => |literal| {
                for (literal.slots) |slot| {
                    _ = try markReachableFunctionByName(reachable, verified.function_sigs, sig_index_by_name, slot.func_name);
                }
            },
            else => {},
        }
    }

    var sig_index: usize = 0;
    var idx: usize = 0;
    while (idx < verified.annotated.len) : (idx += 1) {
        const item = verified.annotated[idx].base;
        switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                if (sig_index >= verified.function_sigs.len) return error.UnknownFunction;
                const fsig = verified.function_sigs[sig_index];
                sig_index += 1;

                const is_main = fsig.kind == .normal and std.mem.eql(u8, fsig.name, "main") and fsig.params.len == 0;
                const is_public_entry = item.kind == .export_decl or item.kind == .ffi_wrapper_decl or item.kind == .extern_decl;
                if (is_main or is_public_entry) {
                    try reachable.put(fsig.name, {});
                }
            },
            else => {},
        }
    }

    var changed = true;
    while (changed) {
        changed = false;
        sig_index = 0;
        idx = 0;
        while (idx < verified.annotated.len) : (idx += 1) {
            const item = verified.annotated[idx].base;
            switch (item.kind) {
                .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                    if (sig_index >= verified.function_sigs.len) return error.UnknownFunction;
                    const fsig = verified.function_sigs[sig_index];
                    sig_index += 1;
                    var end = idx + 1;
                    while (end < verified.annotated.len and switch (verified.annotated[end].base.kind) {
                        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                        else => true,
                    }) : (end += 1) {}

                    if (reachable.contains(fsig.name)) {
                        changed = (try collectBodyDirectCallees(allocator, verified, sig_index_by_name, idx + 1, end, reachable)) or changed;
                    }
                    idx = end - 1;
                },
                else => {},
            }
        }
    }
}

fn isPathSepByte(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn trimTrailingPathSeps(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and isPathSepByte(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

fn pathIsUnderRoot(path: []const u8, root_path: []const u8) bool {
    const root = trimTrailingPathSeps(root_path);
    if (root.len == 0) return false;
    if (std.mem.eql(u8, path, root)) return true;
    return path.len > root.len and std.mem.startsWith(u8, path, root) and isPathSepByte(path[root.len]);
}

fn pathHasSegment(path: []const u8, segment: []const u8) bool {
    var start: usize = 0;
    while (start <= path.len) {
        var end = start;
        while (end < path.len and !isPathSepByte(path[end])) : (end += 1) {}
        if (std.mem.eql(u8, path[start..end], segment)) return true;
        if (end == path.len) break;
        start = end + 1;
    }
    return false;
}

fn functionSourcePath(fsig: sig.FunctionSig, source_path: []const u8) []const u8 {
    if (fsig.upstream_loc) |loc| return loc.file;
    if (fsig.upstream_file) |file| return file;
    return source_path;
}

fn functionHasStdOrigin(fsig: sig.FunctionSig, source_path: []const u8, std_root: ?[]const u8) bool {
    const path = functionSourcePath(fsig, source_path);
    if (std_root) |root| {
        if (pathIsUnderRoot(path, root)) return true;
    }
    return pathHasSegment(path, "sa_std");
}

fn markStdDceUserRoots(reachable: *std.StringHashMap(void), sigs: []const sig.FunctionSig, source_path: []const u8, std_root: ?[]const u8) !void {
    for (sigs) |fsig| {
        if (!functionHasStdOrigin(fsig, source_path, std_root)) try reachable.put(fsig.name, {});
    }
}

fn collectDceReachability(allocator: std.mem.Allocator, verified: anytype, sig_index_by_name: *const std.StringHashMap(usize), source_path: []const u8, options: EmitOptions, reachable: *std.StringHashMap(void)) !void {
    if (options.dce == .std) {
        try markStdDceUserRoots(reachable, verified.function_sigs, source_path, options.std_root);
    }
    try collectNormalBuildReachability(allocator, verified, sig_index_by_name, reachable);
}

fn shouldPruneUnreachableFunction(options: EmitOptions, fsig: sig.FunctionSig, source_path: []const u8) bool {
    return switch (options.dce) {
        .no => false,
        .full => true,
        .std => functionHasStdOrigin(fsig, source_path, options.std_root),
    };
}

fn functionSigShapeEqual(lhs: sig.FunctionSig, rhs: sig.FunctionSig) bool {
    if (lhs.return_cap != rhs.return_cap or lhs.return_ty != rhs.return_ty or lhs.return_fallible != rhs.return_fallible) return false;
    if (lhs.params.len != rhs.params.len) return false;
    for (lhs.params, rhs.params) |lparam, rparam| {
        if (lparam.cap != rparam.cap or lparam.ty != rparam.ty) return false;
    }
    return true;
}

fn offsetFromOperand(op: inst.Operand) ?u64 {
    return switch (op) {
        .imm_u64 => |v| v,
        .imm_i64, .imm_int => |v| if (v >= 0) @intCast(v) else null,
        else => null,
    };
}

fn slotNameFromLoadText(raw: []const u8) ?[]const u8 {
    const plus = std.mem.indexOfScalar(u8, raw, '+') orelse return null;
    const tail = std.mem.trim(u8, raw[plus + 1 ..], " \t\r");
    const as_idx = std.mem.indexOf(u8, tail, " as ") orelse tail.len;
    var token = std.mem.trim(u8, tail[0..as_idx], " \t\r");
    if (token.len == 0) return null;
    if (std.mem.lastIndexOfScalar(u8, token, '_')) |idx| token = token[idx + 1 ..];
    return if (token.len == 0) null else token;
}

fn chooseIndirectSigIndex(state: *BuildState, current: ?usize, candidate: usize) ?usize {
    if (current) |existing| {
        if (existing == candidate) return existing;
        if (functionSigShapeEqual(state.function_sigs[existing], state.function_sigs[candidate])) return existing;
        return null;
    }
    return candidate;
}

fn inferIndirectSigIndexFromSlot(state: *BuildState, slot_name: []const u8) ?usize {
    var resolved: ?usize = null;
    for (state.const_decls) |decl| {
        switch (decl.value) {
            .vtable => |literal| {
                for (literal.slots) |slot| {
                    if (!std.mem.eql(u8, slot.name, slot_name)) continue;
                    const idx = state.function_sig_index.get(slot.func_name) orelse continue;
                    resolved = chooseIndirectSigIndex(state, resolved, idx) orelse return null;
                }
            },
            else => {},
        }
    }
    return resolved;
}

fn inferIndirectSigIndexFromOffset(state: *BuildState, offset: u64) ?usize {
    if (offset % 8 != 0) return null;
    const slot_index: usize = @intCast(offset / 8);
    var resolved: ?usize = null;
    for (state.const_decls) |decl| {
        switch (decl.value) {
            .vtable => |literal| {
                if (slot_index >= literal.slots.len) continue;
                const idx = state.function_sig_index.get(literal.slots[slot_index].func_name) orelse continue;
                resolved = chooseIndirectSigIndex(state, resolved, idx) orelse return null;
            },
            else => {},
        }
    }
    return resolved;
}

fn inferIndirectSigIndexFromLoad(state: *BuildState, base: inst.Instruction) ?usize {
    if (slotNameFromLoadText(base.raw_text)) |slot| {
        if (inferIndirectSigIndexFromSlot(state, slot)) |idx| return idx;
    }
    if (offsetFromOperand(base.operands[2])) |offset| {
        return inferIndirectSigIndexFromOffset(state, offset);
    }
    return null;
}

fn builtinReturnType(name: []const u8) ?CType {
    if (std.mem.eql(u8, name, "sys_argc")) return .i32;
    if (std.mem.eql(u8, name, "sys_argv")) return .ptr;
    if (std.mem.eql(u8, name, "sys_read_file")) return .ptr;
    if (std.mem.eql(u8, name, "sys_write_file")) return .i32;
    if (std.mem.eql(u8, name, "sys_print")) return .void;
    if (std.mem.eql(u8, name, "sys_exit")) return .void;
    if (std.mem.eql(u8, name, "sa_print_bytes")) return .void;
    return null;
}

fn assignTy(kind: inst.InstKind, value: COperand) CType {
    return switch (kind) {
        .raw_cast => .i64,
        .borrow, .assume_safe, .assume_borrow => .ptr,
        .assign => switch (value.kind) {
            .const_ptr => .ptr,
            .imm_i64, .imm_u64 => if (value.ty == .ptr) .ptr else .void,
            .imm_f64 => value.ty,
            else => .void,
        },
        else => .void,
    };
}

fn isFloatOp(opcode: inst.OpKind) bool {
    return switch (opcode) {
        .fadd, .fsub, .fmul, .fdiv, .fneg, .fcmp_eq, .fcmp_ne, .fcmp_lt, .fcmp_le, .fcmp_gt, .fcmp_ge => true,
        else => false,
    };
}

fn opConversionTy(base: inst.Instruction) !CType {
    if (base.operands[2] != .ty) return error.InvalidOperand;
    return try cType(sig.primTypeFromTag(base.operands[2].ty) orelse return error.InvalidOperand);
}

fn rawAssignOperand(state: *BuildState, base: inst.Instruction) ?COperand {
    const eq_idx = std.mem.indexOfScalar(u8, base.raw_text, '=') orelse return null;
    const rhs = std.mem.trim(u8, base.raw_text[eq_idx + 1 ..], " \t\r");
    if (rhs.len == 0) return null;
    if (rhs[0] != '&') return null;
    return state.textOperand(rhs) catch null;
}

fn lowerInstruction(allocator: std.mem.Allocator, state: *BuildState, base: inst.Instruction) !?CInstruction {
    const none = COperand{ .kind = .none, .reg = 0, .i64_value = 0, .u64_value = 0, .f64_value = 0, .ty = .void, .name = null };
    const default_ordering: CAtomicOrdering = .seq_cst;
    const default_rmw: CAtomicRmwOp = .add;
    return switch (base.kind) {
        .label => .{ .op = .label, .dst = 0, .operand0 = none, .operand1 = none, .operand2 = none, .ty = .void, .binary_op = .add, .label = try labelNameZ(allocator, state.symbols, base.operands[1]), .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .alloc, .stack_alloc => |k| .{ .op = if (k == .alloc) .alloc else .stack_alloc, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[1]), .operand1 = none, .operand2 = none, .ty = .ptr, .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .load, .take => blk: {
            const loaded_ty = if (base.operands[3] == .ty) sig.primTypeFromTag(base.operands[3].ty) orelse .i64 else sig.PrimType.i64;
            const indirect_sig_index: u32 = if (loaded_ty == .ptr)
                if (inferIndirectSigIndexFromLoad(state, base)) |idx| @intCast(idx) else std.math.maxInt(u32)
            else
                std.math.maxInt(u32);
            break :blk .{ .op = .load, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[1]), .operand1 = try state.operand(base.operands[2]), .operand2 = none, .ty = try cType(loaded_ty), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = indirect_sig_index };
        },
        .atomic_load => .{ .op = .atomic_load, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[1]), .operand1 = try state.operand(base.operands[2]), .operand2 = none, .ty = try cType(atomicValueType(base, .i64)), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = atomicOrdering(base.atomic_ordering), .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .atomic_store => .{ .op = .atomic_store, .dst = 0, .operand0 = try state.operand(base.operands[0]), .operand1 = try state.operand(base.operands[1]), .operand2 = try state.operand(base.operands[2]), .ty = try cType(atomicValueType(base, .i64)), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = atomicOrdering(base.atomic_ordering), .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .atomic_rmw => .{ .op = .atomic_rmw, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[1]), .operand1 = try state.operand(base.operands[2]), .operand2 = try state.operand(base.operands[3]), .ty = try cType(atomicValueType(base, .i64)), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = atomicOrdering(base.atomic_ordering), .atomic_second_ordering = default_ordering, .atomic_rmw_op = try atomicRmwOp(base.atomic_rmw_op), .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .cmpxchg => blk: {
            const args = try allocator.alloc(COperand, 2);
            args[0] = try state.textOperand(base.atomic_new_text orelse return error.InvalidOperand);
            args[1] = .{ .kind = .reg, .reg = base.operands[1].reg, .i64_value = 0, .u64_value = 0, .f64_value = 0, .ty = .i1, .name = null };
            break :blk .{ .op = .cmpxchg, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[2]), .operand1 = try state.operand(base.operands[3]), .operand2 = try state.textOperand(base.atomic_expected_text orelse return error.InvalidOperand), .ty = try cType(atomicValueType(base, .i64)), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = args.ptr, .arg_count = args.len, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = atomicOrdering(base.atomic_ordering), .atomic_second_ordering = atomicOrdering(base.atomic_second_ordering), .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
        },
        .fence => .{ .op = .fence, .dst = 0, .operand0 = none, .operand1 = none, .operand2 = none, .ty = .void, .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = atomicOrdering(base.atomic_ordering), .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .store => .{ .op = .store, .dst = 0, .operand0 = try state.operand(base.operands[0]), .operand1 = try state.operand(base.operands[1]), .operand2 = try state.operand(base.operands[2]), .ty = if (base.operands[3] == .ty) try cType(sig.primTypeFromTag(base.operands[3].ty) orelse .i64) else .i64, .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .op => blk: {
            const opcode = base.op_kind orelse return error.InvalidOperand;
            if (inst.isTypeConversionOpKind(opcode)) {
                break :blk .{ .op = .assign, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[1]), .operand1 = none, .operand2 = none, .ty = try opConversionTy(base), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
            }
            if (opcode == .fneg) {
                break :blk .{ .op = .op, .dst = base.operands[0].reg, .operand0 = .{ .kind = .imm_f64, .reg = 0, .i64_value = 0, .u64_value = 0, .f64_value = 0.0, .ty = .f64, .name = null }, .operand1 = try state.operand(base.operands[1]), .operand2 = none, .ty = .f64, .binary_op = try binaryOp(opcode), .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
            }
            break :blk .{ .op = .op, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[1]), .operand1 = try state.operand(base.operands[2]), .operand2 = none, .ty = if (isFloatOp(opcode)) .f64 else .i64, .binary_op = try binaryOp(opcode), .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
        },
        .ptr_add => .{ .op = .ptr_add, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[1]), .operand1 = try state.operand(base.operands[2]), .operand2 = none, .ty = .ptr, .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .jmp => .{ .op = .jmp, .dst = 0, .operand0 = none, .operand1 = none, .operand2 = none, .ty = .void, .binary_op = .add, .label = try labelNameZ(allocator, state.symbols, base.operands[1]), .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .br => .{ .op = .br, .dst = 0, .operand0 = try state.operand(base.operands[0]), .operand1 = none, .operand2 = none, .ty = .void, .binary_op = .add, .label = try labelNameZ(allocator, state.symbols, base.operands[1]), .false_label = try labelNameZ(allocator, state.symbols, base.operands[3]), .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .call, .call_indirect, .panic, .panic_msg => blk: {
            var parsed = call.parseCall(allocator, base.raw_text) catch return error.InvalidOperand;
            defer parsed.deinit(allocator);
            if (base.kind == .panic) {
                if (parsed.args.len != 1) return error.InvalidOperand;
                break :blk .{ .op = .panic, .dst = 0, .operand0 = try state.callArgOperand(parsed.args[0]), .operand1 = none, .operand2 = none, .ty = .void, .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
            }
            if (base.kind == .panic_msg) {
                if (parsed.args.len != 3) return error.InvalidOperand;
                const panic_args = try allocator.alloc(COperand, 3);
                errdefer allocator.free(panic_args);
                panic_args[0] = try state.callArgOperand(parsed.args[0]);
                panic_args[1] = try state.callArgOperand(parsed.args[1]);
                panic_args[2] = try state.callArgOperand(parsed.args[2]);
                break :blk .{ .op = .call, .dst = 0, .operand0 = none, .operand1 = none, .operand2 = none, .ty = .void, .binary_op = .add, .label = null, .false_label = null, .callee = "panic_msg", .args = panic_args.ptr, .arg_count = panic_args.len, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
            }
            if (base.kind != .call and base.kind != .call_indirect) break :blk .{ .op = .panic, .dst = 0, .operand0 = none, .operand1 = none, .operand2 = none, .ty = .void, .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = false, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
            const args = try allocator.alloc(COperand, parsed.args.len);
            for (parsed.args, 0..) |arg, idx| args[idx] = try state.callArgOperand(arg);
            const resolved = state.calleeSig(parsed.callee);
            const dst: u32 = if (parsed.dest) |dest| blk2: {
                const id = state.symbols.findId(dest) orelse return error.InvalidOperand;
                break :blk2 state.fsig.slotOf(id) orelse return error.InvalidOperand;
            } else 0;
            if (parsed.is_indirect) {
                const callee_op = try state.textOperand(parsed.callee);
                break :blk .{ .op = .call_indirect, .dst = dst, .operand0 = callee_op, .operand1 = none, .operand2 = none, .ty = .void, .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = args.ptr, .arg_count = args.len, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = parsed.dest != null, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
            }
            const callee_name = if (resolved) |resolved_sig| emittedFunctionName(resolved_sig) else parsed.callee;
            const callee = try allocator.dupeZ(u8, callee_name);
            const call_ty = if (resolved) |resolved_sig| try cType(returnTypeForSig(resolved_sig.return_cap, resolved_sig.return_ty)) else builtinReturnType(parsed.callee) orelse CType.void;
            const call_fallible = if (resolved) |resolved_sig| resolved_sig.return_fallible else false;
            break :blk .{ .op = .call, .dst = dst, .operand0 = none, .operand1 = none, .operand2 = none, .ty = call_ty, .binary_op = .add, .label = null, .false_label = null, .callee = callee.ptr, .args = args.ptr, .arg_count = args.len, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = parsed.dest != null, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = call_fallible, .indirect_sig_index = std.math.maxInt(u32) };
        },
        .try_, .early_return => .{ .op = .try_, .dst = base.operands[0].reg, .operand0 = try state.operand(base.operands[1]), .operand1 = none, .operand2 = none, .ty = try cType(returnTypeForSig(state.fsig.return_cap, state.fsig.return_ty)), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .assign, .borrow, .raw_cast, .assume_safe, .assume_borrow => blk: {
            const value = rawAssignOperand(state, base) orelse try state.operand(base.operands[1]);
            break :blk .{ .op = .assign, .dst = base.operands[0].reg, .operand0 = value, .operand1 = none, .operand2 = none, .ty = assignTy(base.kind, value), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = true, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) };
        },
        .return_ => .{ .op = .ret, .dst = 0, .operand0 = if (base.operands[0] == .none) none else try state.operand(base.operands[0]), .operand1 = none, .operand2 = none, .ty = try cType(returnTypeForSig(state.fsig.return_cap, state.fsig.return_ty)), .binary_op = .add, .label = null, .false_label = null, .callee = null, .args = &.{}, .arg_count = 0, .indirect_param_tys = &.{}, .indirect_param_count = 0, .has_dst = base.operands[0] != .none, .atomic_ordering = default_ordering, .atomic_second_ordering = default_ordering, .atomic_rmw_op = default_rmw, .return_fallible = false, .indirect_sig_index = std.math.maxInt(u32) },
        .move_, .release => null,
        else => error.UnsupportedInstruction,
    };
}

const ParallelEmitTask = struct {
    fsig: sig.FunctionSig,
    kind: CFuncKind,
    emit_main_wrapper: bool,
    start_idx: usize,
    end_idx: usize,
    decl_kind: inst.InstKind,
};

const ParallelEmitJob = struct {
    arena: std.heap.ArenaAllocator,
    err: ?anyerror = null,
    result: ?CFunction = null,
};

fn ParallelEmitContext(comptime VerifiedType: type) type {
    return struct {
        allocator: std.mem.Allocator,
        verified: VerifiedType,
        loc_table: upstream.LocTable,
        source_path: []const u8,
        options: EmitOptions,
        anon_string_names: *const std.StringHashMap([*:0]const u8),
        function_sig_index: *const std.StringHashMap(usize),
        tasks: []const ParallelEmitTask,
        jobs: []ParallelEmitJob,
        next_task: std.atomic.Value(usize),
    };
}

fn chooseEmitWorkerCount(requested_jobs: ?usize, task_count: usize) usize {
    if (task_count < 2) return 1;
    if (requested_jobs) |jobs| {
        return if (jobs <= 1) 1 else @min(jobs, task_count);
    }
    const cpu_count = std.Thread.getCpuCount() catch 1;
    return if (cpu_count <= 1) 1 else @min(cpu_count, task_count);
}

fn emitJobBackingAllocator(parent_allocator: std.mem.Allocator, worker_count: usize) std.mem.Allocator {
    return if (worker_count <= 1) parent_allocator else std.heap.page_allocator;
}

fn emitWorker(comptime VerifiedType: type, context_ptr: *anyopaque) void {
    const context: *ParallelEmitContext(VerifiedType) = @ptrCast(@alignCast(context_ptr));
    while (true) {
        const task_idx = context.next_task.fetchAdd(1, .monotonic);
        if (task_idx >= context.tasks.len) return;

        const task = context.tasks[task_idx];
        const job = &context.jobs[task_idx];
        const a = job.arena.allocator();

        const fsig = task.fsig;
        const entry_loc: CDebugLoc = if (fsig.upstream_loc) |loc|
            .{ .line = loc.line, .col = loc.col }
        else
            .{ .line = fsig.entry_inst_idx + 1, .col = 1 };

        const func_source_path = if (fsig.upstream_loc) |loc| loc.file else context.source_path;
        const func_source_file = a.dupeZ(u8, sourceFileName(func_source_path)) catch |err| {
            job.err = err;
            return;
        };
        const func_source_dir = a.dupeZ(u8, sourceDirName(func_source_path)) catch |err| {
            job.err = err;
            return;
        };

        const params = a.alloc(CParam, fsig.params.len) catch |err| {
            job.err = err;
            return;
        };
        for (fsig.params, 0..) |param, pidx| {
            const pname = a.dupeZ(u8, param.name) catch |err| {
                job.err = err;
                return;
            };
            const reg_id = fsig.param_ids[pidx];
            params[pidx] = .{ .name = pname.ptr, .ty = cType(valueTypeForPrefix(param.cap, param.ty)) catch |err| {
                job.err = err;
                return;
            }, .slot = fsig.slotOf(reg_id) orelse @intCast(pidx) };
        }

        const debug_vars = if (context.options.debug and task.decl_kind != .extern_decl)
            buildDebugVars(a, &context.verified.symbols, fsig, entry_loc) catch |err| {
                job.err = err;
                return;
            }
        else
            @as([]CDebugVar, &.{});

        var insts = std.ArrayList(CInstruction).init(a);
        var debug_locs = std.ArrayList(CDebugLoc).init(a);

        if (task.decl_kind != .extern_decl) {
            var state = BuildState.init(a, &context.verified.symbols, fsig, context.verified.const_decls, context.verified.function_sigs, context.function_sig_index, context.anon_string_names) catch |err| {
                job.err = err;
                return;
            };
            defer state.deinit();
            for (context.verified.annotated[task.start_idx + 1 .. task.end_idx], task.start_idx + 1..) |body_item, annotated_idx| {
                if (lowerInstruction(a, &state, body_item.base) catch |err| {
                    job.err = err;
                    return;
                }) |ci| {
                    insts.append(ci) catch |err| {
                        job.err = err;
                        return;
                    };
                    if (context.options.debug) {
                        debug_locs.append(debugLocForInstruction(body_item.base, context.loc_table[annotated_idx], entry_loc)) catch |err| {
                            job.err = err;
                            return;
                        };
                    }
                }
            }
        }

        const name = a.dupeZ(u8, emittedFunctionName(fsig)) catch |err| {
            job.err = err;
            return;
        };
        const ret_ty = cType(returnTypeForSig(fsig.return_cap, fsig.return_ty)) catch |err| {
            job.err = err;
            return;
        };

        job.result = .{
            .name = name.ptr,
            .kind = task.kind,
            .ret_ty = ret_ty,
            .return_fallible = fsig.return_fallible,
            .params = params.ptr,
            .param_count = params.len,
            .instructions = insts.items.ptr,
            .instruction_count = insts.items.len,
            .source_file = if (context.options.debug) func_source_file.ptr else null,
            .source_dir = if (context.options.debug) func_source_dir.ptr else null,
            .entry_line = if (context.options.debug) entry_loc.line else 0,
            .entry_col = if (context.options.debug) entry_loc.col else 0,
            .debug_locs = debug_locs.items.ptr,
            .debug_loc_count = if (context.options.debug) debug_locs.items.len else 0,
            .debug_vars = debug_vars.ptr,
            .debug_var_count = if (context.options.debug) debug_vars.len else 0,
            .emit_main_wrapper = task.emit_main_wrapper,
        };
    }
}

fn emitLlvmcInternal(allocator: std.mem.Allocator, verified: anytype, def_dict: ?*const flattener.DefDict, loc_table: upstream.LocTable, source_path: []const u8, size_bits: u16, options: EmitOptions, obj_path: ?[]const u8, opt_level: u8) ![]const u8 {
    _ = def_dict;
    if (options.debug and loc_table.len != verified.annotated.len) return error.InvalidOperand;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module_source_file = try a.dupeZ(u8, sourceFileName(source_path));
    const module_source_dir = try a.dupeZ(u8, sourceDirName(source_path));
    var function_sig_index = try buildFunctionSigIndex(a, verified.function_sigs);

    var c_consts = std.ArrayList(CConst).init(a);
    var c_vtables = std.ArrayList(CVTable).init(a);
    var anon_string_names = std.StringHashMap([*:0]const u8).init(a);
    for (verified.const_decls) |decl| {
        switch (decl.value) {
            .vtable => |literal| {
                const funcs = try a.alloc([*:0]const u8, literal.slots.len);
                for (literal.slots, 0..) |slot, slot_idx| {
                    const sig_idx = function_sig_index.get(slot.func_name) orelse return error.UnknownFunction;
                    const fname = try a.dupeZ(u8, emittedFunctionName(verified.function_sigs[sig_idx]));
                    funcs[slot_idx] = fname.ptr;
                }
                const name = try a.dupeZ(u8, decl.name);
                try c_vtables.append(.{ .name = name.ptr, .funcs = funcs.ptr, .func_count = funcs.len });
            },
            else => {
                const len = try constBytesLen(decl.value);
                const bytes = try a.alloc(u8, len);
                try fillConstBytes(bytes, decl.value);
                const name = try a.dupeZ(u8, decl.name);
                try c_consts.append(.{ .name = name.ptr, .data = bytes.ptr, .len = bytes.len });
            },
        }
    }
    try collectAnonStringConsts(a, verified.annotated, &anon_string_names, &c_consts);

    var referenced_functions = std.StringHashMap(void).init(a);
    var prune_unreachable = options.dce != .no and !options.test_mode and options.codegen_unit_index == null and options.function_task_index == null;
    if (prune_unreachable) {
        try collectDceReachability(a, verified, &function_sig_index, source_path, options, &referenced_functions);
        prune_unreachable = referenced_functions.count() != 0;
    } else if (options.codegen_unit_index) |cgu_idx| {
        // Collect functions referenced in Trait vtables
        for (verified.const_decls) |decl| {
            switch (decl.value) {
                .vtable => |literal| {
                    for (literal.slots) |slot| {
                        _ = try markReachableFunctionByName(&referenced_functions, verified.function_sigs, &function_sig_index, slot.func_name);
                    }
                },
                else => {},
            }
        }

        // Collect functions called by functions in this CGU
        var sig_index: usize = 0;
        var idx: usize = 0;
        var task_idx: usize = 0;
        while (idx < verified.annotated.len) : (idx += 1) {
            const item = verified.annotated[idx].base;
            switch (item.kind) {
                .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                    if (sig_index >= verified.function_sigs.len) return error.UnknownFunction;
                    sig_index += 1;
                    var end = idx + 1;
                    while (end < verified.annotated.len and switch (verified.annotated[end].base.kind) {
                        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                        else => true,
                    }) : (end += 1) {}

                    if (task_idx % options.codegen_unit_count == cgu_idx) {
                        _ = try collectBodyDirectCallees(a, verified, &function_sig_index, idx + 1, end, &referenced_functions);
                    }
                    task_idx += 1;
                    idx = end - 1;
                },
                else => {},
            }
        }
    } else if (options.function_task_index) |wanted_task_idx| {
        var sig_index: usize = 0;
        var idx: usize = 0;
        var task_idx: usize = 0;
        while (idx < verified.annotated.len) : (idx += 1) {
            const item = verified.annotated[idx].base;
            switch (item.kind) {
                .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                    if (sig_index >= verified.function_sigs.len) return error.UnknownFunction;
                    sig_index += 1;
                    var end = idx + 1;
                    while (end < verified.annotated.len and switch (verified.annotated[end].base.kind) {
                        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                        else => true,
                    }) : (end += 1) {}

                    if (task_idx == wanted_task_idx) {
                        _ = try collectBodyDirectCallees(a, verified, &function_sig_index, idx + 1, end, &referenced_functions);
                    }
                    task_idx += 1;
                    idx = end - 1;
                },
                else => {},
            }
        }
    }

    var tasks = std.ArrayList(ParallelEmitTask).init(a);
    var sig_index: usize = 0;
    var idx: usize = 0;
    var task_idx: usize = 0;
    while (idx < verified.annotated.len) : (idx += 1) {
        const item = verified.annotated[idx].base;
        switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                if (sig_index >= verified.function_sigs.len) return error.UnknownFunction;
                const fsig = verified.function_sigs[sig_index];
                sig_index += 1;
                var end = idx + 1;
                while (end < verified.annotated.len and switch (verified.annotated[end].base.kind) {
                    .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                    else => true,
                }) : (end += 1) {}

                var c_kind: CFuncKind = switch (item.kind) {
                    .extern_decl => .external,
                    .export_decl => .exported,
                    .ffi_wrapper_decl => .exported,
                    .test_decl => .test_func,
                    else => .normal,
                };
                var emit_wrapper = !options.test_mode and fsig.kind == .normal and std.mem.eql(u8, fsig.name, "main") and fsig.params.len == 0;

                var should_include = true;
                if (options.function_task_index) |wanted_task_idx| {
                    if (task_idx == wanted_task_idx) {
                        // This task is emitted as a cached incremental object.
                    } else if (item.kind == .extern_decl or referenced_functions.contains(fsig.name)) {
                        c_kind = .external;
                        emit_wrapper = false;
                    } else {
                        should_include = false;
                    }
                } else if (options.codegen_unit_index) |cgu_idx| {
                    if (task_idx % options.codegen_unit_count == cgu_idx) {
                        // Belongs to this CGU, define it!
                    } else if (item.kind == .extern_decl or referenced_functions.contains(fsig.name)) {
                        // External declaration needed by this CGU
                        c_kind = .external;
                        emit_wrapper = false;
                    } else {
                        // Not needed at all, completely skip!
                        should_include = false;
                    }
                } else if (prune_unreachable and !referenced_functions.contains(fsig.name) and shouldPruneUnreachableFunction(options, fsig, source_path)) {
                    should_include = false;
                }

                if (should_include) {
                    try tasks.append(.{
                        .fsig = fsig,
                        .kind = c_kind,
                        .emit_main_wrapper = emit_wrapper,
                        .start_idx = idx,
                        .end_idx = end,
                        .decl_kind = if (c_kind == .external) .extern_decl else item.kind,
                    });
                }
                task_idx += 1;
                idx = end - 1;
            },
            else => {},
        }
    }

    const worker_count = chooseEmitWorkerCount(options.jobs, tasks.items.len);
    const jobs = try a.alloc(ParallelEmitJob, tasks.items.len);
    const job_backing_allocator = emitJobBackingAllocator(allocator, worker_count);
    for (jobs) |*job| {
        job.* = .{ .arena = std.heap.ArenaAllocator.init(job_backing_allocator) };
    }
    defer {
        for (jobs) |*job| job.arena.deinit();
    }

    const VerifiedType = @TypeOf(verified);
    var context = ParallelEmitContext(VerifiedType){
        .allocator = allocator,
        .verified = verified,
        .loc_table = loc_table,
        .source_path = source_path,
        .options = options,
        .anon_string_names = &anon_string_names,
        .function_sig_index = &function_sig_index,
        .tasks = tasks.items,
        .jobs = jobs,
        .next_task = std.atomic.Value(usize).init(0),
    };

    if (worker_count <= 1) {
        emitWorker(VerifiedType, &context);
    } else {
        const spawned_count = worker_count - 1;
        var threads = try a.alloc(std.Thread, spawned_count);
        var started_threads: usize = 0;
        errdefer {
            while (started_threads > 0) {
                started_threads -= 1;
                threads[started_threads].join();
            }
        }

        while (started_threads < spawned_count) : (started_threads += 1) {
            threads[started_threads] = try std.Thread.spawn(.{}, emitWorker, .{ VerifiedType, &context });
        }

        emitWorker(VerifiedType, &context);

        while (started_threads > 0) {
            started_threads -= 1;
            threads[started_threads].join();
        }
    }

    var c_funcs = std.ArrayList(CFunction).init(a);
    for (jobs) |job| {
        if (job.err) |err| return err;
        try c_funcs.append(job.result orelse return error.Failed);
    }

    const module = CModule{
        .size_bits = size_bits,
        .wasm_compat = options.wasm_compat,
        .test_mode = options.test_mode,
        .debug = options.debug,
        .is_cgu = options.codegen_unit_count > 1,
        .source_file = if (options.debug) module_source_file.ptr else null,
        .source_dir = if (options.debug) module_source_dir.ptr else null,
        .consts = c_consts.items.ptr,
        .const_count = c_consts.items.len,
        .vtables = c_vtables.items.ptr,
        .vtable_count = c_vtables.items.len,
        .functions = c_funcs.items.ptr,
        .function_count = c_funcs.items.len,
    };

    if (obj_path) |path| {
        const path_z = try a.dupeZ(u8, path);
        var err_msg: ?[*:0]u8 = null;
        if (sa_llvmc_emit_module_object(&module, path_z.ptr, @intCast(opt_level), &err_msg) != 0) {
            if (err_msg) |msg| {
                std.debug.print("llvmc object emit: {s}\n", .{std.mem.sliceTo(msg, 0)});
                sa_llvmc_free(msg);
            }
            return error.Failed;
        }
        return &[_]u8{};
    } else {
        var out_bytes: ?[*]u8 = null;
        var out_len: usize = 0;
        var err_msg: ?[*:0]u8 = null;
        if (sa_llvmc_emit_module_bitcode(&module, @intCast(options.opt_level), &out_bytes, &out_len, &err_msg) != 0) {
            if (err_msg) |msg| {
                std.debug.print("llvmc backend: {s}\n", .{std.mem.sliceTo(msg, 0)});
                sa_llvmc_free(msg);
            }
            return error.Failed;
        }
        errdefer if (out_bytes) |ptr| sa_llvmc_free(ptr);
        return try takeOwnedBitcode(allocator, &out_bytes, &out_len);
    }
}

pub fn emitLlvmc(allocator: std.mem.Allocator, verified: anytype, def_dict: ?*const flattener.DefDict, loc_table: upstream.LocTable, source_path: []const u8, size_bits: u16, options: EmitOptions) ![]const u8 {
    return emitLlvmcInternal(allocator, verified, def_dict, loc_table, source_path, size_bits, options, null, 0);
}

pub fn emitLlvmcToObject(allocator: std.mem.Allocator, verified: anytype, def_dict: ?*const flattener.DefDict, loc_table: upstream.LocTable, source_path: []const u8, size_bits: u16, options: EmitOptions, obj_path: []const u8, opt_level: u8) !void {
    _ = try emitLlvmcInternal(allocator, verified, def_dict, loc_table, source_path, size_bits, options, obj_path, opt_level);
}

pub fn emitLlvmcToArtifacts(allocator: std.mem.Allocator, verified: anytype, def_dict: ?*const flattener.DefDict, loc_table: upstream.LocTable, source_path: []const u8, size_bits: u16, options: EmitOptions, bitcode_path: []const u8, object_path: []const u8, opt_level: u8) !void {
    _ = def_dict;
    if (options.debug and loc_table.len != verified.annotated.len) return error.InvalidOperand;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const module_source_file = try a.dupeZ(u8, sourceFileName(source_path));
    const module_source_dir = try a.dupeZ(u8, sourceDirName(source_path));
    var function_sig_index = try buildFunctionSigIndex(a, verified.function_sigs);

    var c_consts = std.ArrayList(CConst).init(a);
    var c_vtables = std.ArrayList(CVTable).init(a);
    var anon_string_names = std.StringHashMap([*:0]const u8).init(a);
    for (verified.const_decls) |decl| {
        switch (decl.value) {
            .vtable => |literal| {
                const funcs = try a.alloc([*:0]const u8, literal.slots.len);
                for (literal.slots, 0..) |slot, slot_idx| {
                    const sig_idx = function_sig_index.get(slot.func_name) orelse return error.UnknownFunction;
                    const fname = try a.dupeZ(u8, emittedFunctionName(verified.function_sigs[sig_idx]));
                    funcs[slot_idx] = fname.ptr;
                }
                const name = try a.dupeZ(u8, decl.name);
                try c_vtables.append(.{ .name = name.ptr, .funcs = funcs.ptr, .func_count = funcs.len });
            },
            else => {
                const len = try constBytesLen(decl.value);
                const bytes = try a.alloc(u8, len);
                try fillConstBytes(bytes, decl.value);
                const name = try a.dupeZ(u8, decl.name);
                try c_consts.append(.{ .name = name.ptr, .data = bytes.ptr, .len = bytes.len });
            },
        }
    }
    try collectAnonStringConsts(a, verified.annotated, &anon_string_names, &c_consts);

    var referenced_functions = std.StringHashMap(void).init(a);
    var prune_unreachable = options.dce != .no and !options.test_mode and options.codegen_unit_index == null and options.function_task_index == null;
    if (prune_unreachable) {
        try collectDceReachability(a, verified, &function_sig_index, source_path, options, &referenced_functions);
        prune_unreachable = referenced_functions.count() != 0;
    } else if (options.codegen_unit_index) |cgu_idx| {
        for (verified.const_decls) |decl| {
            switch (decl.value) {
                .vtable => |literal| {
                    for (literal.slots) |slot| {
                        _ = try markReachableFunctionByName(&referenced_functions, verified.function_sigs, &function_sig_index, slot.func_name);
                    }
                },
                else => {},
            }
        }

        var sig_index: usize = 0;
        var idx: usize = 0;
        var task_idx: usize = 0;
        while (idx < verified.annotated.len) : (idx += 1) {
            const item = verified.annotated[idx].base;
            switch (item.kind) {
                .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                    if (sig_index >= verified.function_sigs.len) return error.UnknownFunction;
                    sig_index += 1;
                    var end = idx + 1;
                    while (end < verified.annotated.len and switch (verified.annotated[end].base.kind) {
                        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                        else => true,
                    }) : (end += 1) {}

                    if (task_idx % options.codegen_unit_count == cgu_idx) {
                        _ = try collectBodyDirectCallees(a, verified, &function_sig_index, idx + 1, end, &referenced_functions);
                    }
                    task_idx += 1;
                    idx = end - 1;
                },
                else => {},
            }
        }
    } else if (options.function_task_index) |wanted_task_idx| {
        var sig_index: usize = 0;
        var idx: usize = 0;
        var task_idx: usize = 0;
        while (idx < verified.annotated.len) : (idx += 1) {
            const item = verified.annotated[idx].base;
            switch (item.kind) {
                .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                    if (sig_index >= verified.function_sigs.len) return error.UnknownFunction;
                    sig_index += 1;
                    var end = idx + 1;
                    while (end < verified.annotated.len and switch (verified.annotated[end].base.kind) {
                        .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                        else => true,
                    }) : (end += 1) {}

                    if (task_idx == wanted_task_idx) {
                        _ = try collectBodyDirectCallees(a, verified, &function_sig_index, idx + 1, end, &referenced_functions);
                    }
                    task_idx += 1;
                    idx = end - 1;
                },
                else => {},
            }
        }
    }

    var tasks = std.ArrayList(ParallelEmitTask).init(a);
    var sig_index: usize = 0;
    var idx: usize = 0;
    var task_idx: usize = 0;
    while (idx < verified.annotated.len) : (idx += 1) {
        const item = verified.annotated[idx].base;
        switch (item.kind) {
            .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => {
                if (sig_index >= verified.function_sigs.len) return error.UnknownFunction;
                const fsig = verified.function_sigs[sig_index];
                sig_index += 1;
                var end = idx + 1;
                while (end < verified.annotated.len and switch (verified.annotated[end].base.kind) {
                    .func_decl, .ffi_wrapper_decl, .extern_decl, .export_decl, .test_decl => false,
                    else => true,
                }) : (end += 1) {}

                var c_kind: CFuncKind = switch (item.kind) {
                    .extern_decl => .external,
                    .export_decl => .exported,
                    .ffi_wrapper_decl => .exported,
                    .test_decl => .test_func,
                    else => .normal,
                };
                var emit_wrapper = !options.test_mode and fsig.kind == .normal and std.mem.eql(u8, fsig.name, "main") and fsig.params.len == 0;

                var should_include = true;
                if (options.function_task_index) |wanted_task_idx| {
                    if (task_idx == wanted_task_idx) {} else if (item.kind == .extern_decl or referenced_functions.contains(fsig.name)) {
                        c_kind = .external;
                        emit_wrapper = false;
                    } else {
                        should_include = false;
                    }
                } else if (options.codegen_unit_index) |cgu_idx| {
                    if (task_idx % options.codegen_unit_count == cgu_idx) {} else if (item.kind == .extern_decl or referenced_functions.contains(fsig.name)) {
                        c_kind = .external;
                        emit_wrapper = false;
                    } else {
                        should_include = false;
                    }
                } else if (prune_unreachable and !referenced_functions.contains(fsig.name) and shouldPruneUnreachableFunction(options, fsig, source_path)) {
                    should_include = false;
                }

                if (should_include) {
                    try tasks.append(.{
                        .fsig = fsig,
                        .kind = c_kind,
                        .emit_main_wrapper = emit_wrapper,
                        .start_idx = idx,
                        .end_idx = end,
                        .decl_kind = if (c_kind == .external) .extern_decl else item.kind,
                    });
                }
                task_idx += 1;
                idx = end - 1;
            },
            else => {},
        }
    }

    const worker_count = chooseEmitWorkerCount(options.jobs, tasks.items.len);
    const jobs = try a.alloc(ParallelEmitJob, tasks.items.len);
    const job_backing_allocator = emitJobBackingAllocator(allocator, worker_count);
    for (jobs) |*job| job.* = .{ .arena = std.heap.ArenaAllocator.init(job_backing_allocator) };
    defer for (jobs) |*job| job.arena.deinit();

    const VerifiedType = @TypeOf(verified);
    var context = ParallelEmitContext(VerifiedType){
        .allocator = allocator,
        .verified = verified,
        .loc_table = loc_table,
        .source_path = source_path,
        .options = options,
        .anon_string_names = &anon_string_names,
        .function_sig_index = &function_sig_index,
        .tasks = tasks.items,
        .jobs = jobs,
        .next_task = std.atomic.Value(usize).init(0),
    };

    if (worker_count <= 1) {
        emitWorker(VerifiedType, &context);
    } else {
        const spawned_count = worker_count - 1;
        var threads = try a.alloc(std.Thread, spawned_count);
        var started_threads: usize = 0;
        errdefer {
            while (started_threads > 0) {
                started_threads -= 1;
                threads[started_threads].join();
            }
        }

        while (started_threads < spawned_count) : (started_threads += 1) {
            threads[started_threads] = try std.Thread.spawn(.{}, emitWorker, .{ VerifiedType, &context });
        }

        emitWorker(VerifiedType, &context);

        while (started_threads > 0) {
            started_threads -= 1;
            threads[started_threads].join();
        }
    }

    var c_funcs = std.ArrayList(CFunction).init(a);
    for (jobs) |job| {
        if (job.err) |err| return err;
        try c_funcs.append(job.result orelse return error.Failed);
    }

    const module = CModule{
        .size_bits = size_bits,
        .wasm_compat = options.wasm_compat,
        .test_mode = options.test_mode,
        .debug = options.debug,
        .is_cgu = options.codegen_unit_count > 1,
        .source_file = if (options.debug) module_source_file.ptr else null,
        .source_dir = if (options.debug) module_source_dir.ptr else null,
        .consts = c_consts.items.ptr,
        .const_count = c_consts.items.len,
        .vtables = c_vtables.items.ptr,
        .vtable_count = c_vtables.items.len,
        .functions = c_funcs.items.ptr,
        .function_count = c_funcs.items.len,
    };

    const bc_z = try a.dupeZ(u8, bitcode_path);
    const obj_z = try a.dupeZ(u8, object_path);
    var err_msg: ?[*:0]u8 = null;
    if (sa_llvmc_emit_module_artifacts(&module, bc_z.ptr, obj_z.ptr, @intCast(opt_level), &err_msg) != 0) {
        if (err_msg) |msg| {
            std.debug.print("llvmc artifact emit: {s}\n", .{std.mem.sliceTo(msg, 0)});
            sa_llvmc_free(msg);
        }
        return error.Failed;
    }
}

pub fn emitLlvmcToFile(allocator: std.mem.Allocator, verified: anytype, def_dict: ?*const flattener.DefDict, loc_table: upstream.LocTable, source_path: []const u8, size_bits: u16, options: EmitOptions, path: []const u8) !void {
    const verified_bitcode = try emitLlvmc(allocator, verified, def_dict, loc_table, source_path, size_bits, options);
    defer allocator.free(verified_bitcode);
    var file = if (std.fs.path.isAbsolute(path)) try std.fs.createFileAbsolute(path, .{ .truncate = true }) else try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(verified_bitcode);
}

test "function signature index preserves linear alias precedence" {
    const sigs = [_]sig.FunctionSig{
        .{ .id = 0, .name = "one", .params = &.{}, .kind = .normal, .return_cap = null, .return_ty = .void, .entry_inst_idx = 0, .is_ffi_wrapper = false, .llvm_name = "shared" },
        .{ .id = 1, .name = "shared", .params = &.{}, .kind = .normal, .return_cap = null, .return_ty = .void, .entry_inst_idx = 0, .is_ffi_wrapper = false },
        .{ .id = 2, .name = "main", .params = &.{}, .kind = .normal, .return_cap = null, .return_ty = .void, .entry_inst_idx = 0, .is_ffi_wrapper = false },
    };
    var index = try buildFunctionSigIndex(std.testing.allocator, sigs[0..]);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 0), index.get("one").?);
    try std.testing.expectEqual(@as(usize, 0), index.get("shared").?);
    try std.testing.expectEqual(@as(usize, 2), index.get("main").?);
    try std.testing.expectEqual(@as(usize, 2), index.get("saasm_main").?);
}

test "dce modes prune std and user functions at distinct levels" {
    const std_func = sig.FunctionSig{
        .id = 0,
        .name = "std_unused",
        .params = &.{},
        .kind = .normal,
        .return_cap = null,
        .return_ty = .void,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
        .upstream_file = "/tmp/app/sa_std/core/unused.sa",
    };
    const user_func = sig.FunctionSig{
        .id = 1,
        .name = "user_unused",
        .params = &.{},
        .kind = .normal,
        .return_cap = null,
        .return_ty = .void,
        .entry_inst_idx = 0,
        .is_ffi_wrapper = false,
        .upstream_file = "/tmp/app/src/user.sa",
    };

    const source_path = "/tmp/app/src/main.sa";
    try std.testing.expect(shouldPruneUnreachableFunction(.{ .dce = .std, .std_root = "/tmp/app/sa_std" }, std_func, source_path));
    try std.testing.expect(!shouldPruneUnreachableFunction(.{ .dce = .std, .std_root = "/tmp/app/sa_std" }, user_func, source_path));
    try std.testing.expect(shouldPruneUnreachableFunction(.{ .dce = .full, .std_root = "/tmp/app/sa_std" }, user_func, source_path));
    try std.testing.expect(!shouldPruneUnreachableFunction(.{ .dce = .no, .std_root = "/tmp/app/sa_std" }, std_func, source_path));
}

test "llvmc backend can construct and write bitcode in memory" {
    var out_bytes: ?[*]u8 = null;
    var out_len: usize = 0;
    var err_msg: ?[*:0]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), sa_llvmc_make_minimal_module_bitcode(&out_bytes, &out_len, &err_msg));
    defer if (err_msg) |msg| sa_llvmc_free(msg);
    defer if (out_bytes) |ptr| sa_llvmc_free(ptr);
    try std.testing.expect(out_bytes != null);
    try std.testing.expect(out_len > 0);
}
