const std = @import("std");

pub const Optimization = enum {
    release_small,
    release_fast,
};

pub const Target = struct {
    triple: []const u8,
    no_entry: bool = false,
    import_symbols: bool = false,
    exports: []const []const u8 = &.{},
};

pub const CompileError = error{
    ChildProcessFailed,
    InvalidTarget,
    MissingTarget,
};

pub const Argv = struct {
    items: [16][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Argv) []const []const u8 {
        return self.items[0..self.len];
    }
};

pub const WasmArgv = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8,
    owned_args: []const []const u8,

    pub fn slice(self: *const WasmArgv) []const []const u8 {
        return self.items;
    }

    pub fn deinit(self: *WasmArgv) void {
        for (self.owned_args) |arg| self.allocator.free(arg);
        self.allocator.free(self.owned_args);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn argvForExe(
    artifact_path: []const u8,
    out_path: []const u8,
    optimization: Optimization,
    sa_std_archive_path: []const u8,
    extra_inputs: []const []const u8,
    debug: bool,
) Argv {
    var argv: Argv = .{};
    argv.items[0] = "zig";
    argv.items[1] = "cc";
    var index: usize = 2;
    if (debug) {
        argv.items[index] = "-g";
        index += 1;
    }
    argv.items[index] = if (debug) "-O0" else switch (optimization) {
        .release_small => "-O1",
        .release_fast => "-O3",
    };
    index += 1;
    argv.items[index] = artifact_path;
    index += 1;
    argv.items[index] = sa_std_archive_path;
    index += 1;
    for (extra_inputs) |input| {
        argv.items[index] = input;
        index += 1;
    }
    argv.items[index] = "-Wl,-rpath,$ORIGIN";
    index += 1;
    argv.items[index] = "-o";
    index += 1;
    argv.items[index] = out_path;
    index += 1;
    argv.len = index;
    return argv;
}

pub fn argvForObj(
    artifact_path: []const u8,
    out_path: []const u8,
    optimization: Optimization,
    debug: bool,
) Argv {
    var argv: Argv = .{};
    argv.items[0] = "zig";
    argv.items[1] = "cc";
    var index: usize = 2;
    if (debug) {
        argv.items[index] = "-g";
        index += 1;
    }
    argv.items[index] = if (debug) "-O0" else switch (optimization) {
        .release_small => "-O1",
        .release_fast => "-O3",
    };
    index += 1;
    argv.items[index] = "-c";
    index += 1;
    argv.items[index] = artifact_path;
    index += 1;
    argv.items[index] = "-o";
    index += 1;
    argv.items[index] = out_path;
    index += 1;
    argv.len = index;
    return argv;
}

pub fn argvForWasm(
    allocator: std.mem.Allocator,
    artifact_path: []const u8,
    out_path: []const u8,
    target: Target,
    optimization: Optimization,
    debug: bool,
) !WasmArgv {
    var argv = std.ArrayList([]const u8).init(allocator);
    errdefer argv.deinit();

    var owned_args = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (owned_args.items) |arg| allocator.free(arg);
        owned_args.deinit();
    }

    try argv.appendSlice(&.{ "zig", "build-exe", artifact_path });
    if (debug) {
        try argv.append("-g");
    }

    try argv.appendSlice(&.{ "-target", target.triple });

    if (target.no_entry) {
        try argv.append("-fno-entry");
    }
    if (target.import_symbols) {
        try argv.append("--import-symbols");
    }
    for (target.exports) |export_name| {
        const arg = try std.fmt.allocPrint(allocator, "--export={s}", .{export_name});
        var owned = false;
        errdefer if (!owned) allocator.free(arg);
        try owned_args.append(arg);
        owned = true;
        try argv.append(arg);
    }

    try argv.append("-O");
    try argv.append(if (debug) "Debug" else switch (optimization) {
        .release_small => "ReleaseSmall",
        .release_fast => "ReleaseFast",
    });

    const emit_bin = try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{out_path});
    var emit_bin_owned = false;
    errdefer if (!emit_bin_owned) allocator.free(emit_bin);
    try owned_args.append(emit_bin);
    emit_bin_owned = true;
    try argv.append(emit_bin);

    const items = try argv.toOwnedSlice();
    errdefer allocator.free(items);
    const owned = try owned_args.toOwnedSlice();

    return .{
        .allocator = allocator,
        .items = items,
        .owned_args = owned,
    };
}

fn runProcess(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
}

fn runProcessFast(allocator: std.mem.Allocator, argv: []const []const u8) !std.process.Child.Term {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    try child.waitForSpawn();
    return try child.wait();
}

fn printCommandLine(writer: anytype, argv: []const []const u8) !void {
    try writer.writeAll("  command:");
    for (argv) |arg| {
        try writer.print(" {s}", .{arg});
    }
    try writer.writeByte('\n');
}

fn printOutputSection(writer: anytype, label: []const u8, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    try writer.print("  {s}:\n", .{label});
    try writer.writeAll(bytes);
    if (bytes[bytes.len - 1] != '\n') try writer.writeByte('\n');
}

fn printCompilerLaunchFailure(writer: anytype, argv: []const []const u8, action: []const u8, input_path: []const u8, out_path: []const u8, err: anyerror) !void {
    try writer.print("error[ExternalCompiler]: failed to launch zig while {s} {s} -> {s}: {s}\n", .{ action, input_path, out_path, @errorName(err) });
    try printCommandLine(writer, argv);
}

fn printCompilerFailure(writer: anytype, argv: []const []const u8, action: []const u8, input_path: []const u8, out_path: []const u8, result: std.process.Child.RunResult) !void {
    switch (result.term) {
        .Exited => |code| try writer.print("error[ExternalCompiler]: zig exited with code {d} while {s} {s} -> {s}\n", .{ code, action, input_path, out_path }),
        else => try writer.print("error[ExternalCompiler]: zig terminated unexpectedly while {s} {s} -> {s}\n", .{ action, input_path, out_path }),
    }
    try printCommandLine(writer, argv);
    try printOutputSection(writer, "stdout", result.stdout);
    try printOutputSection(writer, "stderr", result.stderr);
}

pub fn compileExe(
    allocator: std.mem.Allocator,
    artifact_path: []const u8,
    out_path: []const u8,
    optimization: Optimization,
    sa_std_archive_path: []const u8,
    extra_inputs: []const []const u8,
    debug: bool,
    stderr: anytype,
) !void {
    const argv = argvForExe(artifact_path, out_path, optimization, sa_std_archive_path, extra_inputs, debug);
    const argv_slice = argv.slice();
    const term = runProcessFast(allocator, argv_slice) catch |err| {
        try printCompilerLaunchFailure(stderr, argv_slice, "linking", artifact_path, out_path, err);
        return CompileError.ChildProcessFailed;
    };

    const failed = switch (term) {
        .Exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        const result = runProcess(allocator, argv_slice) catch |err| {
            try printCompilerLaunchFailure(stderr, argv_slice, "linking", artifact_path, out_path, err);
            return CompileError.ChildProcessFailed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try printCompilerFailure(stderr, argv_slice, "linking", artifact_path, out_path, result);
        return CompileError.ChildProcessFailed;
    }
}

pub fn compileObj(
    allocator: std.mem.Allocator,
    artifact_path: []const u8,
    out_path: []const u8,
    optimization: Optimization,
    debug: bool,
    stderr: anytype,
) !void {
    const argv = argvForObj(artifact_path, out_path, optimization, debug);
    const argv_slice = argv.slice();
    const term = runProcessFast(allocator, argv_slice) catch |err| {
        try printCompilerLaunchFailure(stderr, argv_slice, "compiling object", artifact_path, out_path, err);
        return CompileError.ChildProcessFailed;
    };

    const failed = switch (term) {
        .Exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        const result = runProcess(allocator, argv_slice) catch |err| {
            try printCompilerLaunchFailure(stderr, argv_slice, "compiling object", artifact_path, out_path, err);
            return CompileError.ChildProcessFailed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try printCompilerFailure(stderr, argv_slice, "compiling object", artifact_path, out_path, result);
        return CompileError.ChildProcessFailed;
    }
}

pub fn compileWasm(
    allocator: std.mem.Allocator,
    artifact_path: []const u8,
    out_path: []const u8,
    target: Target,
    optimization: Optimization,
    debug: bool,
    stderr: anytype,
) !void {
    var argv = try argvForWasm(allocator, artifact_path, out_path, target, optimization, debug);
    defer argv.deinit();
    const argv_slice = argv.slice();
    const term = runProcessFast(allocator, argv_slice) catch |err| {
        try printCompilerLaunchFailure(stderr, argv_slice, "linking wasm", artifact_path, out_path, err);
        return CompileError.ChildProcessFailed;
    };

    const failed = switch (term) {
        .Exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        const result = runProcess(allocator, argv_slice) catch |err| {
            try printCompilerLaunchFailure(stderr, argv_slice, "linking wasm", artifact_path, out_path, err);
            return CompileError.ChildProcessFailed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try printCompilerFailure(stderr, argv_slice, "linking wasm", artifact_path, out_path, result);
        return CompileError.ChildProcessFailed;
    }
}

test "argv helpers choose the requested optimization" {
    const exe_small = argvForExe("input.bc", "out.exe", .release_small, "/repo/artifacts/sa_std/libsa_std.a", &.{}, false);
    try std.testing.expectEqualStrings("-O1", exe_small.slice()[2]);
    try std.testing.expectEqualStrings("/repo/artifacts/sa_std/libsa_std.a", exe_small.slice()[4]);
    const exe_fast = argvForExe("input.bc", "out.exe", .release_fast, "/repo/artifacts/sa_std/libsa_std.a", &.{}, false);
    try std.testing.expectEqualStrings("-O3", exe_fast.slice()[2]);

    var wasm_small = try argvForWasm(std.testing.allocator, "input.bc", "out.wasm", .{ .triple = "wasm32-wasi" }, .release_small, false);
    defer wasm_small.deinit();
    try std.testing.expectEqualStrings("build-exe", wasm_small.slice()[1]);
    try std.testing.expectEqualStrings("ReleaseSmall", wasm_small.slice()[6]);

    var wasm_fast = try argvForWasm(std.testing.allocator, "input.bc", "out.wasm", .{
        .triple = "wasm32-wasi",
        .no_entry = true,
        .import_symbols = true,
        .exports = &.{"sax_app_init"},
    }, .release_fast, false);
    defer wasm_fast.deinit();
    try std.testing.expectEqualStrings("-fno-entry", wasm_fast.slice()[5]);
    try std.testing.expectEqualStrings("--import-symbols", wasm_fast.slice()[6]);
    try std.testing.expectEqualStrings("--export=sax_app_init", wasm_fast.slice()[7]);
    try std.testing.expectEqualStrings("ReleaseFast", wasm_fast.slice()[9]);
}
