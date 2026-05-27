const std = @import("std");

const Kind = struct {
    const function: u8 = 0;
    const table: u8 = 1;
    const memory: u8 = 2;
    const global: u8 = 3;
};

const Symbol = struct {
    module: []const u8 = "",
    name: []const u8,
    kind: u8,
};

const required_imports = [_]Symbol{
    .{ .module = "env", .name = "malloc", .kind = Kind.function },
    .{ .module = "env", .name = "sax_dom_query", .kind = Kind.function },
    .{ .module = "env", .name = "sax_dom_create", .kind = Kind.function },
    .{ .module = "env", .name = "sax_dom_set_attr", .kind = Kind.function },
    .{ .module = "env", .name = "sax_dom_bind_event", .kind = Kind.function },
    .{ .module = "env", .name = "sax_dom_append_child", .kind = Kind.function },
    .{ .module = "env", .name = "sax_mem_copy", .kind = Kind.function },
    .{ .module = "env", .name = "sax_dom_set_text", .kind = Kind.function },
    .{ .module = "env", .name = "sax_itoa", .kind = Kind.function },
    .{ .module = "env", .name = "sax_dom_remove_self", .kind = Kind.function },
};

const optional_imports = [_]Symbol{
    .{ .module = "env", .name = "sax_ftoa_bits", .kind = Kind.function },
};

const Found = struct {
    imports: [required_imports.len]bool = [_]bool{false} ** required_imports.len,
    optional_imports: [optional_imports.len]bool = [_]bool{false} ** optional_imports.len,
    memory_export: bool = false,
    app_init_export: bool = false,
    function_exports: []bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len < 3) {
        try std.io.getStdErr().writer().print("usage: {s} <sax-demo-output-dir> <expected-function-export>...\n", .{args[0]});
        return error.InvalidArguments;
    }
    const expected_function_exports = args[2..];

    const wasm_path = try std.fs.path.join(allocator, &.{ args[1], "app.wasm" });
    defer allocator.free(wasm_path);
    const airlock_path = try std.fs.path.join(allocator, &.{ args[1], "airlock.js" });
    defer allocator.free(airlock_path);
    const app_sa_path = try std.fs.path.join(allocator, &.{ args[1], "app.sa" });
    defer allocator.free(app_sa_path);

    const wasm = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 16 * 1024 * 1024);
    defer allocator.free(wasm);
    if (wasm.len < 1024) {
        try std.io.getStdErr().writer().print("SAX demo wasm is unexpectedly small: {d} bytes\n", .{wasm.len});
        return error.InvalidDemoWasm;
    }

    var found = Found{
        .function_exports = try allocator.alloc(bool, expected_function_exports.len),
    };
    defer allocator.free(found.function_exports);
    @memset(found.function_exports, false);
    try scanWasm(wasm, expected_function_exports, &found);
    try reportMissing(&found, expected_function_exports);

    const airlock = try std.fs.cwd().readFileAlloc(allocator, airlock_path, 16 * 1024 * 1024);
    defer allocator.free(airlock);
    if (!std.mem.containsAtLeast(u8, airlock, 1, "malloc(size)") or
        !std.mem.containsAtLeast(u8, airlock, 1, "return _malloc(size);") or
        !std.mem.containsAtLeast(u8, airlock, 1, "free(_ptr)") or
        std.mem.containsAtLeast(u8, airlock, 1, "return BigInt(_malloc(size));"))
    {
        try std.io.getStdErr().writer().writeAll("airlock.js does not expose the expected wasm32 malloc/free imports\n");
        return error.InvalidAirlock;
    }

    const app_sa = try std.fs.cwd().readFileAlloc(allocator, app_sa_path, 16 * 1024 * 1024);
    defer allocator.free(app_sa);
    if (std.mem.containsAtLeast(u8, app_sa, 1, "call @sax_ftoa_bits(")) {
        if (!found.optional_imports[0]) {
            try std.io.getStdErr().writer().writeAll("missing wasm import env.sax_ftoa_bits:function\n");
            return error.MissingWasmSymbol;
        }
        if (!std.mem.containsAtLeast(u8, airlock, 1, "sax_ftoa_bits(value_bits, decimals, buf_ptr, buf_len)")) {
            try std.io.getStdErr().writer().writeAll("airlock.js does not expose sax_ftoa_bits for f64 state formatting\n");
            return error.InvalidAirlock;
        }
    }
    if (std.mem.containsAtLeast(u8, app_sa, 1, "@extern sax_dom_bind_event")) {
        if (!std.mem.containsAtLeast(u8, app_sa, 1, "utf8:\"click\"") or
            std.mem.containsAtLeast(u8, app_sa, 1, "utf8:\"onclick\""))
        {
            try std.io.getStdErr().writer().writeAll("app.sa binds browser events with SAX attribute names instead of DOM event names\n");
            return error.InvalidDemoEventBinding;
        }
    }
}

fn scanWasm(bytes: []const u8, expected_function_exports: []const []const u8, found: *Found) !void {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "\x00asm") or
        !std.mem.eql(u8, bytes[4..8], "\x01\x00\x00\x00"))
    {
        return error.InvalidWasmHeader;
    }

    var index: usize = 8;
    while (index < bytes.len) {
        const section_id = try readByte(bytes, &index);
        const section_size = try readLebU32(bytes, &index);
        const section_end = try checkedSectionEnd(index, section_size, bytes.len);
        const section = bytes[index..section_end];

        switch (section_id) {
            2 => try scanImportSection(section, found),
            7 => try scanExportSection(section, expected_function_exports, found),
            else => {},
        }

        index = section_end;
    }
}

fn scanImportSection(section: []const u8, found: *Found) !void {
    var index: usize = 0;
    const count = try readLebU32(section, &index);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const module = try readName(section, &index);
        const name = try readName(section, &index);
        const kind = try readByte(section, &index);
        for (required_imports, 0..) |symbol, symbol_index| {
            if (symbol.kind == kind and std.mem.eql(u8, symbol.module, module) and std.mem.eql(u8, symbol.name, name)) {
                found.imports[symbol_index] = true;
            }
        }
        for (optional_imports, 0..) |symbol, symbol_index| {
            if (symbol.kind == kind and std.mem.eql(u8, symbol.module, module) and std.mem.eql(u8, symbol.name, name)) {
                found.optional_imports[symbol_index] = true;
            }
        }
        try skipImportDescriptor(section, &index, kind);
    }
    if (index != section.len) return error.InvalidImportSection;
}

fn scanExportSection(section: []const u8, expected_function_exports: []const []const u8, found: *Found) !void {
    var index: usize = 0;
    const count = try readLebU32(section, &index);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const name = try readName(section, &index);
        const kind = try readByte(section, &index);
        _ = try readLebU32(section, &index);
        if (kind == Kind.memory and std.mem.eql(u8, "memory", name)) {
            found.memory_export = true;
            continue;
        }
        if (kind == Kind.function and std.mem.eql(u8, "sax_app_init", name)) {
            found.app_init_export = true;
            continue;
        }
        if (kind == Kind.function) {
            for (expected_function_exports, 0..) |symbol_name, symbol_index| {
                if (std.mem.eql(u8, symbol_name, name)) {
                    found.function_exports[symbol_index] = true;
                }
            }
        }
    }
    if (index != section.len) return error.InvalidExportSection;
}

fn reportMissing(found: *const Found, expected_function_exports: []const []const u8) !void {
    var ok = true;
    const stderr = std.io.getStdErr().writer();
    for (required_imports, 0..) |symbol, index| {
        if (!found.imports[index]) {
            ok = false;
            try stderr.print("missing wasm import {s}.{s}:{s}\n", .{ symbol.module, symbol.name, kindName(symbol.kind) });
        }
    }
    if (!found.memory_export) {
        ok = false;
        try stderr.writeAll("missing wasm export memory:memory\n");
    }
    if (!found.app_init_export) {
        ok = false;
        try stderr.writeAll("missing wasm export sax_app_init:function\n");
    }
    for (expected_function_exports, 0..) |symbol_name, index| {
        if (!found.function_exports[index]) {
            ok = false;
            try stderr.print("missing wasm export {s}:function\n", .{symbol_name});
        }
    }
    if (!ok) return error.MissingWasmSymbol;
}

fn readByte(bytes: []const u8, index: *usize) !u8 {
    if (index.* >= bytes.len) return error.UnexpectedEof;
    const value = bytes[index.*];
    index.* += 1;
    return value;
}

fn readLebU32(bytes: []const u8, index: *usize) !u32 {
    var value: u32 = 0;
    var shift: u6 = 0;
    while (true) {
        if (shift >= 32) return error.InvalidLeb;
        const byte = try readByte(bytes, index);
        const s: u5 = @intCast(shift);
        value |= @as(u32, byte & 0x7f) << s;
        if ((byte & 0x80) == 0) return value;
        shift += 7;
    }
}

fn readName(bytes: []const u8, index: *usize) ![]const u8 {
    const len = try readLebU32(bytes, index);
    const end = try checkedSectionEnd(index.*, len, bytes.len);
    const name = bytes[index.*..end];
    index.* = end;
    return name;
}

fn checkedSectionEnd(start: usize, size: u32, limit: usize) !usize {
    const end = std.math.add(usize, start, @as(usize, size)) catch return error.InvalidSectionSize;
    if (end > limit) return error.UnexpectedEof;
    return end;
}

fn skipImportDescriptor(bytes: []const u8, index: *usize, kind: u8) !void {
    switch (kind) {
        Kind.function => _ = try readLebU32(bytes, index),
        Kind.table => {
            _ = try readByte(bytes, index);
            try skipLimits(bytes, index);
        },
        Kind.memory => try skipLimits(bytes, index),
        Kind.global => {
            _ = try readByte(bytes, index);
            _ = try readByte(bytes, index);
        },
        else => return error.InvalidImportKind,
    }
}

fn skipLimits(bytes: []const u8, index: *usize) !void {
    const flags = try readLebU32(bytes, index);
    _ = try readLebU32(bytes, index);
    if ((flags & 0x01) != 0) _ = try readLebU32(bytes, index);
}

fn kindName(kind: u8) []const u8 {
    return switch (kind) {
        Kind.function => "function",
        Kind.table => "table",
        Kind.memory => "memory",
        Kind.global => "global",
        else => "unknown",
    };
}
