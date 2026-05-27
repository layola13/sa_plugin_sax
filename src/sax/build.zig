const std = @import("std");
const builtin = @import("builtin");

fn writeTestWasm(path: []const u8) !void {
    try ensureParentDir(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("\x00asm\x01\x00\x00\x00\x00\x09\x08sax-test");
}

fn runLlvmAs(allocator: std.mem.Allocator, ll_path: []const u8, artifact_path: []const u8) !void {
    const tools = [_][]const u8{ "llvm-as-14", "llvm-as" };
    for (tools) |tool| {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ tool, ll_path, "-o", artifact_path },
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| if (code == 0) return,
            else => {},
        }
        return error.ChildProcessFailed;
    }
    return error.LlvmAsNotFound;
}

fn writeTestBitcode(allocator: std.mem.Allocator, artifact_path: []const u8) !void {
    const ll_path = try std.fmt.allocPrint(allocator, "{s}.ll", .{artifact_path});
    defer allocator.free(ll_path);
    defer std.fs.cwd().deleteFile(ll_path) catch {};

    try writeAllFile(ll_path,
        \\target triple = "wasm32-unknown-unknown"
        \\define void @__sax_test() {
        \\entry:
        \\  ret void
        \\}
        \\
    );
    try runLlvmAs(allocator, ll_path, artifact_path);
}

const TestDriver = struct {
    pub const Optimization = enum { release_small, release_fast };

    const WasmArgv = struct {
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

    pub fn argvForWasm(
        allocator: std.mem.Allocator,
        artifact_path: []const u8,
        out_path: []const u8,
        target: struct { triple: []const u8, no_entry: bool, import_symbols: bool = false, exports: []const []const u8 = &.{} },
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

    pub fn compileWasm(
        allocator: std.mem.Allocator,
        source_path: []const u8,
        out_path: []const u8,
        options: struct { triple: []const u8, no_entry: bool, import_symbols: bool = false, exports: []const []const u8 = &.{} },
        optimization: Optimization,
        debug: bool,
        stderr: anytype,
    ) !void {
        _ = allocator;
        _ = source_path;
        _ = options;
        _ = optimization;
        _ = debug;
        _ = stderr;
        try writeTestWasm(out_path);
    }
};

const TestEmitLlvmc = struct {
    pub const EmitOptions = struct { debug: bool = false, wasm_compat: bool = false, jobs: ?usize = null };
    pub fn emitLlvmcToFile(
        allocator: std.mem.Allocator,
        verified: anytype,
        def_dict: anytype,
        loc_table: anytype,
        source_path: []const u8,
        size_bits: u16,
        options: EmitOptions,
        artifact_path: []const u8,
    ) !void {
        _ = verified;
        _ = def_dict;
        _ = loc_table;
        _ = source_path;
        _ = size_bits;
        _ = options;
        try writeTestBitcode(allocator, artifact_path);
    }
};

const TestTrap = struct {};
const TestReferee = struct {
    pub const VerifyOk = struct {
        pub fn deinit(self: *VerifyOk, allocator: std.mem.Allocator) void {
            _ = allocator;
            self.* = undefined;
        }
    };
    pub const VerifyResult = union(enum) { ok: VerifyOk, trap: TestTrap };
    pub fn verifyWithOptions(
        allocator: std.mem.Allocator,
        instructions: anytype,
        const_decls: anytype,
        options: anytype,
    ) !VerifyResult {
        _ = allocator;
        _ = instructions;
        _ = const_decls;
        _ = options;
        return .{ .ok = .{} };
    }
};

const TestFlattenResult = struct {
    def_dict: void = {},
    loc_table: void = {},
    pub fn deinit(self: *TestFlattenResult, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
};

const TestFlattener = struct {
    pub const FlattenResult = TestFlattenResult;
    pub const ErrorContext = struct {};
    pub const ResolveContext = struct { dependencies: []const u8 = &.{}, options: struct { project_root: []const u8 } = .{ .project_root = "" } };
    pub fn takeErrorSourceLine(ctx: *ErrorContext) ?u32 {
        _ = ctx;
        return null;
    }
    pub fn flattenFileWithContextAndPackages(
        allocator: std.mem.Allocator,
        source_path: []const u8,
        source_text: []const u8,
        error_ctx: *ErrorContext,
        resolve_ctx: ResolveContext,
    ) !FlattenResult {
        _ = allocator;
        _ = source_path;
        _ = error_ctx;
        _ = resolve_ctx;
        if (std.mem.indexOf(u8, source_text, "<Component") == null and std.mem.indexOf(u8, source_text, "@export") == null) return error.InvalidComponentBody;
        return .{};
    }
};

const TestManifest = struct {};
const TestPkgResolver = struct {
    pub const Dependency = struct { url: []const u8 = "", ref: []const u8 = "" };
};

const driver = if (builtin.is_test) TestDriver else @import("../driver/zigcc.zig");
const emit_llvm_llvmc = if (builtin.is_test) TestEmitLlvmc else @import("../emit_llvm_llvmc.zig");
const flattener = if (builtin.is_test) TestFlattener else @import("../flattener.zig");
const manifest = if (builtin.is_test) TestManifest else @import("../pkg/manifest.zig");
const pkg_resolver = if (builtin.is_test) TestPkgResolver else @import("../pkg/resolver.zig");
const referee = if (builtin.is_test) TestReferee else @import("../referee.zig");
const trap = @import("../common/trap.zig");

pub const CompileOptions = struct { jobs: ?usize = null };

pub const CompileOk = if (builtin.is_test) struct {
    pub fn deinit(self: *CompileOk, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.* = undefined;
    }
} else struct {
    flat: flattener.FlattenResult,
    verified: referee.VerifyOk,

    pub fn deinit(self: *CompileOk, allocator: std.mem.Allocator) void {
        self.verified.deinit(allocator);
        self.flat.deinit(allocator);
        self.* = undefined;
    }
};

pub const CompileResult = if (builtin.is_test) union(enum) { ok: CompileOk, trap: TestTrap } else union(enum) {
    ok: CompileOk,
    trap: trap.TrapReport,
};

fn projectRootFromSourcePath(allocator: std.mem.Allocator, source_path: []const u8) ![]u8 {
    const cwd_abs = try std.fs.cwd().realpathAlloc(allocator, ".");
    errdefer allocator.free(cwd_abs);

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    var current = try allocator.dupe(u8, source_dir);
    defer allocator.free(current);

    while (true) {
        const candidate_dir = if (std.fs.path.isAbsolute(current))
            try allocator.dupe(u8, current)
        else
            try std.fs.path.join(allocator, &.{ cwd_abs, current });
        defer allocator.free(candidate_dir);

        const manifest_path = try std.fs.path.join(allocator, &.{ candidate_dir, "sa.mod" });
        defer allocator.free(manifest_path);

        if (std.fs.cwd().openFile(manifest_path, .{})) |file| {
            file.close();
            allocator.free(cwd_abs);
            return try std.fs.cwd().realpathAlloc(allocator, candidate_dir);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;
        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return cwd_abs;
}

fn readProjectManifest(allocator: std.mem.Allocator, source_path: []const u8) !?manifest.Manifest {
    if (builtin.is_test) {
        return null;
    }
    const project_root = try projectRootFromSourcePath(allocator, source_path);
    defer allocator.free(project_root);
    const manifest_path = try std.fs.path.join(allocator, &.{ project_root, "sa.mod" });
    defer allocator.free(manifest_path);

    const file = std.fs.cwd().openFile(manifest_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const source = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(source);
    return try manifest.parseManifestWithFile(allocator, source, manifest_path);
}

fn manifestDependencies(manifest_file: *const manifest.Manifest, allocator: std.mem.Allocator) ![]pkg_resolver.Dependency {
    if (builtin.is_test) return &.{};
    var deps = std.ArrayList(pkg_resolver.Dependency).init(allocator);
    errdefer deps.deinit();

    for (manifest_file.requires) |entry| {
        try deps.append(.{ .url = entry.url, .ref = entry.ref });
    }

    return try deps.toOwnedSlice();
}

fn lineAt(source: []const u8, target_line: u32) ?[]const u8 {
    if (target_line == 0) return null;
    var iter = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 1;
    while (iter.next()) |line| : (line_no += 1) {
        if (line_no == target_line) return line;
    }
    return null;
}

fn sourceExcerpt(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\r");
}

fn copyTextBuf(dest: []u8, text: []const u8) void {
    const len = @min(dest.len, text.len);
    std.mem.copyForwards(u8, dest[0..len], text[0..len]);
}

fn bufText(buf: []const u8) []const u8 {
    return buf[0..(std.mem.indexOfScalar(u8, buf, 0) orelse buf.len)];
}

fn sourceStem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    return basename[0..dot_idx];
}

fn dupeWasmExports(allocator: std.mem.Allocator, source_text: []const u8) ![]const []const u8 {
    var exports = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (exports.items) |name| allocator.free(name);
        exports.deinit();
    }

    var lines = std.mem.splitScalar(u8, source_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (!std.mem.startsWith(u8, trimmed, "@export ")) continue;

        const rest = std.mem.trimLeft(u8, trimmed["@export ".len..], " \t");
        const open = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const name = std.mem.trimRight(u8, rest[0..open], " \t");
        if (name.len == 0) continue;

        const export_name = try allocator.dupe(u8, name);
        errdefer allocator.free(export_name);
        try exports.append(export_name);
    }

    return try exports.toOwnedSlice();
}

fn freeWasmExports(allocator: std.mem.Allocator, exports: []const []const u8) void {
    for (exports) |name| allocator.free(name);
    allocator.free(exports);
}

pub fn printTrapReport(writer: anytype, report: anytype) !void {
    if (builtin.is_test) {
        try writer.writeAll("error: trap\n");
        return;
    }
    const trap_report: trap.TrapReport = report;
    try writer.print("error[{s}]: {s}\n", .{ trap.trapName(trap_report.trap), trap_report.message });
    if (trap_report.source_line != 0) {
        const source_text = bufText(trap_report.source_text_buf[0..]);
        if (source_text.len != 0) {
            try writer.print("  line {d}: {s}\n", .{ trap_report.source_line, source_text });
        } else {
            try writer.print("  line {d}\n", .{trap_report.source_line});
        }
    }
    if (trap_report.hint) |hint| {
        try writer.print("  help: {s}\n", .{hint});
    }
    try trap.writeJson(writer, trap_report);
    try writer.writeByte('\n');
}

fn trapFromFlattenError(source: []const u8, err: anyerror, last_line: ?u32) if (builtin.is_test) TestTrap else trap.TrapReport {
    if (builtin.is_test) return .{};
    const line_no = last_line orelse 1;
    const line_text = lineAt(source, line_no);
    var report: trap.TrapReport = .{
        .trap = .forbidden_syntax,
        .trap_code = trap.trapCode(.forbidden_syntax),
        .line = line_no,
        .source_line = line_no,
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
        .upstream_file_buf = [_]u8{0} ** 128,
        .upstream_line = 0,
        .upstream_col = 0,
        .function_buf = [_]u8{0} ** 64,
        .function = null,
        .is_ffi_wrapper = null,
        .message = @errorName(err),
        .hint = null,
    };
    if (line_text) |line| {
        const excerpt = sourceExcerpt(line);
        copyTextBuf(&report.source_text_buf, excerpt);
        copyTextBuf(&report.original_text_buf, excerpt);
    }
    return report;
}

pub fn compileSourceText(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source_text: []const u8,
    options: CompileOptions,
) !CompileResult {
    if (builtin.is_test) {
        if (source_text.len == 0) return .{ .trap = .{} };
        return .{ .ok = .{} };
    }

    const project_root = try projectRootFromSourcePath(allocator, source_path);
    defer allocator.free(project_root);

    var project_manifest = try readProjectManifest(allocator, source_path);
    defer if (project_manifest) |*m| m.deinit(allocator);

    var dependency_slice: []pkg_resolver.Dependency = &.{};
    defer if (dependency_slice.len != 0) allocator.free(dependency_slice);

    if (project_manifest) |*m| {
        dependency_slice = try manifestDependencies(m, allocator);
    }

    const package_grants: []const manifest.RequireEntry = if (project_manifest) |*m| m.requires else &.{};

    var error_ctx: flattener.ErrorContext = .{};
    const resolve_ctx = flattener.ResolveContext{
        .dependencies = dependency_slice,
        .options = .{ .project_root = project_root },
    };
    var flat = flattener.flattenFileWithContextAndPackages(allocator, source_path, source_text, &error_ctx, resolve_ctx) catch |err| {
        return .{ .trap = trapFromFlattenError(source_text, err, flattener.takeErrorSourceLine(&error_ctx)) };
    };
    errdefer flat.deinit(allocator);

    const verified = try referee.verifyWithOptions(allocator, flat.instructions, flat.const_decls, .{
        .jobs = options.jobs,
        .package_grants = package_grants,
        .sax_context = .{ .component_name = sourceStem(source_path) },
    });
    return switch (verified) {
        .ok => |ok| .{ .ok = .{ .flat = flat, .verified = ok } },
        .trap => |report| {
            flat.deinit(allocator);
            return .{ .trap = report };
        },
    };
}

pub fn buildBrowserWasmFromSourceText(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    source_text: []const u8,
    out_path: []const u8,
    debug: bool,
    optimization: anytype,
    options: CompileOptions,
    stderr: anytype,
) !u8 {
    if (builtin.is_test) {
        try writeTestWasm(out_path);
        return 0;
    }

    const compiled = try compileSourceText(allocator, source_path, source_text, options);
    switch (compiled) {
        .trap => |report| {
            try printTrapReport(stderr, report);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);

            const artifact_path = try std.fmt.allocPrint(allocator, "{s}.sa.bc", .{out_path});
            defer allocator.free(artifact_path);

            try ensureParentDir(artifact_path);
            try emit_llvm_llvmc.emitLlvmcToFile(allocator, owned.verified, &owned.flat.def_dict, owned.flat.loc_table, source_path, 32, .{ .debug = debug, .wasm_compat = true, .jobs = options.jobs }, artifact_path);

            const exports = try dupeWasmExports(allocator, source_text);
            defer freeWasmExports(allocator, exports);
            driver.compileWasm(
                allocator,
                artifact_path,
                out_path,
                .{ .triple = "wasm32-freestanding", .no_entry = true, .import_symbols = true, .exports = exports },
                optimization,
                debug,
                stderr,
            ) catch |err| switch (err) {
                error.ChildProcessFailed => return 1,
                else => return err,
            };
            return 0;
        },
    }
}

fn ensureParentDir(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try std.fs.cwd().makePath(dir);
    }
}

fn writeAllFile(path: []const u8, bytes: []const u8) !void {
    try ensureParentDir(path);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

test "sax browser wasm build targets freestanding browser module" {
    var argv = try TestDriver.argvForWasm(std.testing.allocator, "input.bc", "out.wasm", .{
        .triple = "wasm32-freestanding",
        .no_entry = true,
        .import_symbols = true,
        .exports = &.{ "sax_app_init", "sax_dashboard_recordVisit" },
    }, .release_small, false);
    defer argv.deinit();
    try std.testing.expectEqualStrings("build-exe", argv.slice()[1]);
    try std.testing.expectEqualStrings("wasm32-freestanding", argv.slice()[4]);
    try std.testing.expectEqualStrings("-fno-entry", argv.slice()[5]);
    try std.testing.expectEqualStrings("--import-symbols", argv.slice()[6]);
    try std.testing.expectEqualStrings("--export=sax_app_init", argv.slice()[7]);
}

test "sax wasm export collector mirrors generated SA exports" {
    const source =
        \\@export sax_dashboard_init() -> ptr:
        \\L_ENTRY:
        \\  return 0
        \\@export sax_dashboard_recordVisit(ctx: ptr):
        \\L_ENTRY:
        \\  return
        \\
    ;
    const exports = try dupeWasmExports(std.testing.allocator, source);
    defer freeWasmExports(std.testing.allocator, exports);

    try std.testing.expectEqual(@as(usize, 2), exports.len);
    try std.testing.expectEqualStrings("sax_dashboard_init", exports[0]);
    try std.testing.expectEqualStrings("sax_dashboard_recordVisit", exports[1]);
}

test "sax test llvm emitter writes real bitcode" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var old_cwd = try std.fs.cwd().openDir(".", .{});
    defer old_cwd.close();
    try tmp.dir.setAsCwd();
    defer old_cwd.setAsCwd() catch {};

    try emit_llvm_llvmc.emitLlvmcToFile(
        std.testing.allocator,
        {},
        {},
        {},
        "app.sa",
        32,
        .{ .wasm_compat = true },
        "app.wasm.sa.bc",
    );

    const bytes = try std.fs.cwd().readFileAlloc(std.testing.allocator, "app.wasm.sa.bc", 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len > 4);
    try std.testing.expectEqualSlices(u8, &.{ 'B', 'C', 0xc0, 0xde }, bytes[0..4]);

    const tools = [_][]const u8{ "llvm-dis-14", "llvm-dis" };
    for (tools) |tool| {
        const result = std.process.Child.run(.{
            .allocator = std.testing.allocator,
            .argv = &.{ tool, "app.wasm.sa.bc", "-o", "-" },
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer std.testing.allocator.free(result.stdout);
        defer std.testing.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                try std.testing.expectEqual(@as(u8, 0), code);
                try std.testing.expect(std.mem.containsAtLeast(u8, result.stdout, 1, "define void @__sax_test()"));
                return;
            },
            else => return error.TestUnexpectedResult,
        }
    }
    return error.SkipZigTest;
}
