const std = @import("std");

const upstream = @import("upstream_loc.zig");

pub const Trap = enum(u8) {
    forbidden_syntax,
    duplicate_def,
    duplicate_label,
    unsupported_type,
    import_resolution_failed,
    macro_recursion_limit,
    register_redefinition,
    unknown_register,
    borrow_conflict,
    use_after_move,
    double_mutable_borrow,
    read_write_conflict,
    memory_leak,
    capability_mismatch,
    fallthrough_forbidden,
    phi_state_conflict,
    gas_exceeded,
    arena_oom,
    snapshot_version_mismatch,
    illegal_unsafe_context,
    ffi_ownership_violation,
    unsupported_sys_intrinsic,
    interior_ptr_escape,
    const_mutation,
    vtable_signature_mismatch,
    stack_escape,
    unauthorized_primitive,
    upstream_sha_mismatch,
    early_return_leak,
    fallible_contract_mismatch,
    invalid_atomic_ordering,
    atomic_ordering_mismatch,
    test_func_signature_mismatch,
    db_capability_escalation,
    db_memory_guard_violation,
    db_blob_arena_oom,
    db_concurrency_conflict,
    db_schema_mismatch,
    db_cursor_overflow,
    db_column_type_mismatch,
    db_query_hash_unknown,
    db_blob_handle_invalid,
    db_snapshot_corrupted,
    db_duplicate_register,
    db_forbidden_sql_string,
    sax_state_leak,
    sax_event_escape,
    sax_render_outside_handler,
    sax_invalid_interpolation,
    sax_state_write_from_outside,
    sax_unknown_tag,
    sax_unknown_event,
};

pub const TrapReport = struct {
    trap: Trap,
    trap_code: ?u32 = null,
    line: u32,
    source_line: u32,
    source_text_buf: [256]u8 = [_]u8{0} ** 256,
    original_text_buf: [256]u8 = [_]u8{0} ** 256,
    source_text: ?[]const u8 = null,
    original_text: ?[]const u8 = null,
    register_buf: [64]u8 = [_]u8{0} ** 64,
    register: ?[]const u8 = null,
    registers: []const []const u8 = &.{},
    expected_mask: ?u16 = null,
    actual_mask: ?u16 = null,
    expected_mask_name: ?[]const u8 = null,
    actual_mask_name: ?[]const u8 = null,
    upstream_loc: ?upstream.UpstreamLoc = null,
    upstream_file_buf: [128]u8 = [_]u8{0} ** 128,
    upstream_line: u32 = 0,
    upstream_col: u32 = 0,
    function_buf: [64]u8 = [_]u8{0} ** 64,
    function: ?[]const u8 = null,
    is_ffi_wrapper: ?bool = null,
    repair_action: ?[]const u8 = null,
    repair_hint: ?[]const u8 = null,
    repair_confidence: ?[]const u8 = null,
    message: []const u8,
    hint: ?[]const u8 = null,
};

pub fn trapName(trap: Trap) []const u8 {
    return switch (trap) {
        .forbidden_syntax => "ForbiddenSyntax",
        .duplicate_def => "DuplicateDef",
        .duplicate_label => "DuplicateLabel",
        .unsupported_type => "UnsupportedType",
        .import_resolution_failed => "ImportResolutionFailed",
        .macro_recursion_limit => "MacroRecursionLimit",
        .register_redefinition => "RegisterRedefinition",
        .unknown_register => "UnknownRegister",
        .borrow_conflict => "BorrowConflict",
        .use_after_move => "UseAfterMove",
        .double_mutable_borrow => "DoubleMutableBorrow",
        .read_write_conflict => "ReadWriteConflict",
        .memory_leak => "MemoryLeak",
        .capability_mismatch => "CapabilityMismatch",
        .fallthrough_forbidden => "FallthroughForbidden",
        .phi_state_conflict => "PhiStateConflict",
        .gas_exceeded => "GasExceeded",
        .arena_oom => "ArenaOOM",
        .snapshot_version_mismatch => "SnapshotVersionMismatch",
        .illegal_unsafe_context => "IllegalUnsafeContext",
        .ffi_ownership_violation => "FfiOwnershipViolation",
        .unsupported_sys_intrinsic => "UnsupportedSysIntrinsic",
        .interior_ptr_escape => "InteriorPtrEscape",
        .const_mutation => "ConstMutation",
        .vtable_signature_mismatch => "VTableSignatureMismatch",
        .stack_escape => "StackEscape",
        .unauthorized_primitive => "UnauthorizedPrimitive",
        .upstream_sha_mismatch => "UpstreamShaMismatch",
        .early_return_leak => "EarlyReturnLeak",
        .fallible_contract_mismatch => "FallibleContractMismatch",
        .invalid_atomic_ordering => "InvalidAtomicOrdering",
        .atomic_ordering_mismatch => "AtomicOrderingMismatch",
        .test_func_signature_mismatch => "TestFuncSignatureMismatch",
        .db_capability_escalation => "DbCapabilityEscalation",
        .db_memory_guard_violation => "DbMemoryGuardViolation",
        .db_blob_arena_oom => "DbBlobArenaOOM",
        .db_concurrency_conflict => "DbConcurrencyConflict",
        .db_schema_mismatch => "DbSchemaMismatch",
        .db_cursor_overflow => "DbCursorOverflow",
        .db_column_type_mismatch => "DbColumnTypeMismatch",
        .db_query_hash_unknown => "DbQueryHashUnknown",
        .db_blob_handle_invalid => "DbBlobHandleInvalid",
        .db_snapshot_corrupted => "DbSnapshotCorrupted",
        .db_duplicate_register => "DbDuplicateRegister",
        .db_forbidden_sql_string => "DbForbiddenSqlString",
        .sax_state_leak => "SaxStateLeak",
        .sax_event_escape => "SaxEventEscape",
        .sax_render_outside_handler => "SaxRenderOutsideHandler",
        .sax_invalid_interpolation => "SaxInvalidInterpolation",
        .sax_state_write_from_outside => "SaxStateWriteFromOutside",
        .sax_unknown_tag => "SaxUnknownTag",
        .sax_unknown_event => "SaxUnknownEvent",
    };
}

pub fn trapCode(trap: Trap) u32 {
    return switch (trap) {
        .forbidden_syntax => 1001,
        .duplicate_def => 1002,
        .duplicate_label => 1003,
        .unsupported_type => 1004,
        .import_resolution_failed => 1050,
        .macro_recursion_limit => 1005,
        .register_redefinition => 1006,
        .unknown_register => 1007,
        .borrow_conflict => 1008,
        .use_after_move => 1009,
        .double_mutable_borrow => 1010,
        .read_write_conflict => 1011,
        .memory_leak => 1012,
        .capability_mismatch => 1013,
        .fallthrough_forbidden => 1014,
        .phi_state_conflict => 1015,
        .gas_exceeded => 1016,
        .arena_oom => 1017,
        .snapshot_version_mismatch => 1018,
        .illegal_unsafe_context => 1019,
        .ffi_ownership_violation => 1020,
        .unsupported_sys_intrinsic => 1021,
        .interior_ptr_escape => 1022,
        .const_mutation => 1023,
        .vtable_signature_mismatch => 1024,
        .stack_escape => 1025,
        .unauthorized_primitive => 1043,
        .upstream_sha_mismatch => 1044,
        .early_return_leak => 1026,
        .fallible_contract_mismatch => 1027,
        .invalid_atomic_ordering => 1028,
        .atomic_ordering_mismatch => 1029,
        .test_func_signature_mismatch => 1030,
        .db_capability_escalation => 1031,
        .db_memory_guard_violation => 1032,
        .db_blob_arena_oom => 1033,
        .db_concurrency_conflict => 1034,
        .db_schema_mismatch => 1035,
        .db_cursor_overflow => 1036,
        .db_column_type_mismatch => 1037,
        .db_query_hash_unknown => 1038,
        .db_blob_handle_invalid => 1039,
        .db_snapshot_corrupted => 1040,
        .db_duplicate_register => 1041,
        .db_forbidden_sql_string => 1042,
        .sax_state_leak => 1045,
        .sax_event_escape => 1046,
        .sax_render_outside_handler => 1047,
        .sax_invalid_interpolation => 1048,
        .sax_state_write_from_outside => 1049,
        .sax_unknown_tag => 1051,
        .sax_unknown_event => 1052,
    };
}

fn writeJsonString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{X:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn writeMaybeString(writer: anytype, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn bufText(buf: []const u8) []const u8 {
    return buf[0..(std.mem.indexOfScalar(u8, buf, 0) orelse buf.len)];
}

fn writeStringOrBuf(writer: anytype, value: ?[]const u8, buf: []const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        const fallback = bufText(buf);
        if (fallback.len == 0) {
            try writer.writeAll("null");
        } else {
            try writeJsonString(writer, fallback);
        }
    }
}

fn writeMaybeBool(writer: anytype, value: ?bool) !void {
    if (value) |v| {
        try writer.writeAll(if (v) "true" else "false");
    } else {
        try writer.writeAll("null");
    }
}

fn writeMaybeRepair(writer: anytype, value: ?[]const u8) !void {
    try writeMaybeString(writer, value);
}

fn writeMaybeU16(writer: anytype, value: ?u16) !void {
    if (value) |v| {
        try writer.print("{d}", .{v});
    } else {
        try writer.writeAll("null");
    }
}

fn writeMaybeU32(writer: anytype, value: ?u32) !void {
    if (value) |v| {
        try writer.print("{d}", .{v});
    } else {
        try writer.writeAll("null");
    }
}

pub fn writeJson(writer: anytype, report: TrapReport) !void {
    try writer.writeAll("{");
    try writer.writeAll("\"trap\":");
    try writeJsonString(writer, trapName(report.trap));
    try writer.writeAll(",\"trap_code\":");
    try writeMaybeU32(writer, report.trap_code);
    try writer.writeAll(",\"line\":");
    try writer.print("{d}", .{report.line});
    try writer.writeAll(",\"source_line\":");
    try writer.print("{d}", .{report.source_line});
    try writer.writeAll(",\"source_text\":");
    try writeStringOrBuf(writer, report.source_text, &report.source_text_buf);
    try writer.writeAll(",\"original_text\":");
    try writeStringOrBuf(writer, report.original_text, &report.original_text_buf);
    try writer.writeAll(",\"register\":");
    try writeStringOrBuf(writer, report.register, &report.register_buf);
    try writer.writeAll(",\"registers\":[");
    for (report.registers, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeAll("],\"expected_mask\":");
    try writeMaybeU16(writer, report.expected_mask);
    try writer.writeAll(",\"actual_mask\":");
    try writeMaybeU16(writer, report.actual_mask);
    try writer.writeAll(",\"expected_mask_name\":");
    try writeMaybeString(writer, report.expected_mask_name);
    try writer.writeAll(",\"actual_mask_name\":");
    try writeMaybeString(writer, report.actual_mask_name);
    try writer.writeAll(",\"upstream_loc\":");
    if (report.upstream_loc) |loc| {
        try writer.writeByte('{');
        try writer.writeAll("\"file\":");
        try writeJsonString(writer, loc.file);
        try writer.writeAll(",\"line\":");
        try writer.print("{d}", .{loc.line});
        try writer.writeAll(",\"col\":");
        try writer.print("{d}", .{loc.col});
        try writer.writeByte('}');
    } else if (report.upstream_file_buf[0] != 0) {
        try writer.writeByte('{');
        try writer.writeAll("\"file\":");
        try writeJsonString(writer, bufText(&report.upstream_file_buf));
        try writer.writeAll(",\"line\":");
        try writer.print("{d}", .{report.upstream_line});
        try writer.writeAll(",\"col\":");
        try writer.print("{d}", .{report.upstream_col});
        try writer.writeByte('}');
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"function\":");
    try writeStringOrBuf(writer, report.function, &report.function_buf);
    try writer.writeAll(",\"is_ffi_wrapper\":");
    try writeMaybeBool(writer, report.is_ffi_wrapper);
    if (report.repair_action != null or report.repair_hint != null or report.repair_confidence != null) {
        try writer.writeAll(",\"repair\":");
        try writer.writeByte('{');
        try writer.writeAll("\"action\":");
        try writeMaybeRepair(writer, report.repair_action);
        try writer.writeAll(",\"hint\":");
        try writeMaybeRepair(writer, report.repair_hint);
        try writer.writeAll(",\"confidence\":");
        try writeMaybeRepair(writer, report.repair_confidence);
        try writer.writeByte('}');
    }
    try writer.writeAll(",\"message\":");
    try writeJsonString(writer, report.message);
    try writer.writeAll(",\"hint\":");
    try writeMaybeString(writer, report.hint);
    try writer.writeAll("}");
}

test "trap names are stable" {
    try std.testing.expectEqualStrings("ForbiddenSyntax", trapName(.forbidden_syntax));
    try std.testing.expectEqualStrings("MemoryLeak", trapName(.memory_leak));
    try std.testing.expectEqualStrings("InteriorPtrEscape", trapName(.interior_ptr_escape));
    try std.testing.expectEqualStrings("UnauthorizedPrimitive", trapName(.unauthorized_primitive));
    try std.testing.expectEqualStrings("UpstreamShaMismatch", trapName(.upstream_sha_mismatch));
    try std.testing.expectEqualStrings("SaxStateLeak", trapName(.sax_state_leak));
    try std.testing.expectEqualStrings("ImportResolutionFailed", trapName(.import_resolution_failed));
}

test "trap codes are explicit and stable" {
    try std.testing.expectEqual(@as(u32, 1001), trapCode(.forbidden_syntax));
    try std.testing.expectEqual(@as(u32, 1012), trapCode(.memory_leak));
    try std.testing.expectEqual(@as(u32, 1022), trapCode(.interior_ptr_escape));
    try std.testing.expectEqual(@as(u32, 1043), trapCode(.unauthorized_primitive));
    try std.testing.expectEqual(@as(u32, 1044), trapCode(.upstream_sha_mismatch));
    try std.testing.expectEqual(@as(u32, 1045), trapCode(.sax_state_leak));
    try std.testing.expectEqual(@as(u32, 1050), trapCode(.import_resolution_failed));
}

test "trap json serialization is stable" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const report = TrapReport{
        .trap = .memory_leak,
        .trap_code = 11,
        .line = 12,
        .source_line = 9,
        .source_text = "result = load node+0 as i32",
        .original_text = "result = load node+0 as i32",
        .register = "r1",
        .registers = &.{ "r1", "r2" },
        .expected_mask = 0x01,
        .actual_mask = 0x08,
        .expected_mask_name = "Active",
        .actual_mask_name = "Consumed",
        .upstream_loc = .{ .file = "main.rs", .line = 42, .col = 7 },
        .function = "main",
        .is_ffi_wrapper = false,
        .message = "live registers remain at function exit",
        .hint = "insert explicit release",
    };

    try writeJson(list.writer(), report);
    try std.testing.expectEqualStrings(
        "{\"trap\":\"MemoryLeak\",\"trap_code\":11,\"line\":12,\"source_line\":9,\"source_text\":\"result = load node+0 as i32\",\"original_text\":\"result = load node+0 as i32\",\"register\":\"r1\",\"registers\":[\"r1\",\"r2\"],\"expected_mask\":1,\"actual_mask\":8,\"expected_mask_name\":\"Active\",\"actual_mask_name\":\"Consumed\",\"upstream_loc\":{\"file\":\"main.rs\",\"line\":42,\"col\":7},\"function\":\"main\",\"is_ffi_wrapper\":false,\"message\":\"live registers remain at function exit\",\"hint\":\"insert explicit release\"}",
        list.items,
    );
}

test "trap json serialization emits null for absent optional strings" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const report = TrapReport{
        .trap = .forbidden_syntax,
        .trap_code = 1,
        .line = 1,
        .source_line = 1,
        .source_text_buf = [_]u8{0} ** 256,
        .original_text_buf = [_]u8{0} ** 256,
        .source_text = null,
        .original_text = null,
        .register = null,
        .registers = &.{},
        .expected_mask = null,
        .actual_mask = null,
        .expected_mask_name = null,
        .actual_mask_name = null,
        .upstream_loc = null,
        .function = null,
        .is_ffi_wrapper = null,
        .message = "forbidden syntax detected during flattening",
        .hint = null,
    };

    try writeJson(list.writer(), report);
    try std.testing.expectEqualStrings(
        "{\"trap\":\"ForbiddenSyntax\",\"trap_code\":1,\"line\":1,\"source_line\":1,\"source_text\":null,\"original_text\":null,\"register\":null,\"registers\":[],\"expected_mask\":null,\"actual_mask\":null,\"expected_mask_name\":null,\"actual_mask_name\":null,\"upstream_loc\":null,\"function\":null,\"is_ffi_wrapper\":null,\"message\":\"forbidden syntax detected during flattening\",\"hint\":null}",
        list.items,
    );
}

test "trap json serialization falls back to owned buffers" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    var report = TrapReport{
        .trap = .memory_leak,
        .trap_code = 1012,
        .line = 12,
        .source_line = 9,
        .source_text_buf = [_]u8{0} ** 256,
        .original_text_buf = [_]u8{0} ** 256,
        .source_text = null,
        .original_text = null,
        .register = null,
        .registers = &.{},
        .expected_mask = null,
        .actual_mask = null,
        .expected_mask_name = null,
        .actual_mask_name = null,
        .upstream_loc = null,
        .function = null,
        .is_ffi_wrapper = null,
        .message = "live registers remain at function exit",
        .hint = null,
    };
    const text = "result = load node+0 as i32";
    std.mem.copyForwards(u8, report.source_text_buf[0..text.len], text);
    std.mem.copyForwards(u8, report.original_text_buf[0..text.len], text);

    try writeJson(list.writer(), report);
    try std.testing.expectEqualStrings(
        "{\"trap\":\"MemoryLeak\",\"trap_code\":1012,\"line\":12,\"source_line\":9,\"source_text\":\"result = load node+0 as i32\",\"original_text\":\"result = load node+0 as i32\",\"register\":null,\"registers\":[],\"expected_mask\":null,\"actual_mask\":null,\"expected_mask_name\":null,\"actual_mask_name\":null,\"upstream_loc\":null,\"function\":null,\"is_ffi_wrapper\":null,\"message\":\"live registers remain at function exit\",\"hint\":null}",
        list.items,
    );
}

test "trap json serialization emits repair object when present" {
    var list = std.ArrayList(u8).init(std.testing.allocator);
    defer list.deinit();

    const report = TrapReport{
        .trap = .forbidden_syntax,
        .trap_code = 1001,
        .line = 4,
        .source_line = 4,
        .message = "forbidden syntax detected during flattening",
        .repair_action = "rewrite",
        .repair_hint = "lower structured control flow into labels, branches, and explicit register moves",
        .repair_confidence = "high",
    };

    try writeJson(list.writer(), report);
    try std.testing.expect(std.mem.containsAtLeast(u8, list.items, 1, "\"repair\":{\"action\":\"rewrite\",\"hint\":\"lower structured control flow into labels, branches, and explicit register moves\",\"confidence\":\"high\"}"));
}

test "db trap names and codes are stable" {
    try std.testing.expectEqualStrings("DbCapabilityEscalation", trapName(.db_capability_escalation));
    try std.testing.expectEqualStrings("DbForbiddenSqlString", trapName(.db_forbidden_sql_string));
    try std.testing.expectEqual(@as(u32, 1031), trapCode(.db_capability_escalation));
    try std.testing.expectEqual(@as(u32, 1042), trapCode(.db_forbidden_sql_string));
}
