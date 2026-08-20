const std = @import("std");
const builtin = @import("builtin");
const plugin_api = @import("plugin_api");
const parser = @import("sax/parser.zig");
const lowerer = @import("sax/lowerer.zig");
const airlock_gen = @import("sax/airlock_gen.zig");
const sax_build = @import("sax/build.zig");

const skills = [_]plugin_api.SkillSection{
    .{
        .name = "sax",
        .summary = "Standalone SAX project commands",
        .items = &.{
            "sax build <file> [--out-dir <dir>]",
            "sax check <file>",
            "sax dev <file> [--out-dir <dir>]",
            "sax new <name>",
        },
    },
};

const SaxArtifacts = struct {
    component_name: []const u8,
    root_name: []u8,
    sa_code: std.ArrayList(u8),
    airlock_js: std.ArrayList(u8),
    wgpu_airlock_js: ?std.ArrayList(u8),
    sa3d_airlock_js: ?std.ArrayList(u8),
    index_html: std.ArrayList(u8),

    fn deinit(self: *SaxArtifacts, allocator: std.mem.Allocator) void {
        allocator.free(self.root_name);
        self.sa_code.deinit();
        self.airlock_js.deinit();
        if (self.wgpu_airlock_js) |*js| js.deinit();
        if (self.sa3d_airlock_js) |*js| js.deinit();
        self.index_html.deinit();
        self.* = undefined;
    }
};

const SidecarSupport = struct {
    prelude: std.ArrayList(u8),
    airlock_js: std.ArrayList(u8),

    fn deinit(self: *SidecarSupport) void {
        self.prelude.deinit();
        self.airlock_js.deinit();
        self.* = undefined;
    }
};

const SidecarSpec = struct {
    label: []const u8,
    error_tag: []const u8,
    share_env: []const u8,
    share_env_alt: ?[]const u8 = null,
    airlock_env: []const u8,
    installed_name: []const u8,
    lib_name: []const u8,
    path_token: []const u8,
    dev_share_dir: []const u8,
    sai_file: []const u8,
    sal_file: []const u8,
    airlock_file: ?[]const u8,
};

const wgpu_sidecar = SidecarSpec{
    .label = "WGPU",
    .error_tag = "SA-SAX-WGPU",
    .share_env = "SA_WGPU_SHARE_DIR",
    .airlock_env = "SA_WGPU_AIRLOCK_JS",
    .installed_name = "wgpu",
    .lib_name = if (builtin.os.tag == .windows) "wgpu.dll" else "libwgpu.so",
    .path_token = "sa_plugin_wgpu",
    .dev_share_dir = if (builtin.os.tag == .windows) "E:/projects/sla/sa_plugin_wgpu/zig-out/share" else "/home/vscode/projects/sa_plugins/sa_plugin_wgpu/zig-out/share",
    .sai_file = "wgpu.sai",
    .sal_file = "wgpu.sal",
    .airlock_file = "wgpu_airlock.js",
};

const sa3d_sidecar = SidecarSpec{
    .label = "SA3D",
    .error_tag = "SA-SAX-SA3D",
    .share_env = "SA_3D_SHARE_DIR",
    .share_env_alt = "SA3D_SHARE_DIR",
    .airlock_env = "SA_3D_AIRLOCK_JS",
    .installed_name = "3d",
    .lib_name = if (builtin.os.tag == .windows) "3d.dll" else "lib3d.so",
    .path_token = "sa_plugin_3d",
    .dev_share_dir = if (builtin.os.tag == .windows) "E:/projects/sla/sa_plugin_3dengines/sa_plugin_3d/zig-out/share" else "/home/vscode/projects/sa_plugins/sa_plugin_3dengines/sa_plugin_3d/zig-out/share",
    .sai_file = "sa3d.sai",
    .sal_file = "sa3d.sal",
    .airlock_file = "sa3d_airlock.js",
};

const sa3d_render_wgpu_sidecar = SidecarSpec{
    .label = "SA3D_RENDER_WGPU",
    .error_tag = "SA-SAX-SA3D-RENDER-WGPU",
    .share_env = "SA_3D_RENDER_WGPU_SHARE_DIR",
    .airlock_env = "SA_3D_RENDER_WGPU_AIRLOCK_JS",
    .installed_name = "3d_render_wgpu",
    .lib_name = if (builtin.os.tag == .windows) "3d_render_wgpu.dll" else "lib3d_render_wgpu.so",
    .path_token = "sa_plugin_3d_render_wgpu",
    .dev_share_dir = if (builtin.os.tag == .windows) "E:/projects/sla/sa_plugin_3dengines/sa_plugin_3d_render_wgpu/zig-out/share" else "/home/vscode/projects/sa_plugins/sa_plugin_3dengines/sa_plugin_3d_render_wgpu/zig-out/share",
    .sai_file = "3d_render_wgpu.sai",
    .sal_file = "3d_render_wgpu.sal",
    .airlock_file = null,
};

const ValidationError = enum {
    SaxStateLeak,
    SaxEventEscape,
    SaxRenderOutsideHandler,
    SaxInvalidInterpolation,
    SaxStateWriteFromOutside,
    SaxInvalidNativeEscape,
};

const ValidationFailure = struct {
    component_name: []const u8,
    err: ValidationError,
    line: u32,
    text: []const u8,
};

fn cArgvToSlice(argv: [*]const [*:0]const u8, argv_len: usize, allocator: std.mem.Allocator) ![]const []const u8 {
    const slice = argv[0..argv_len];
    var out = try allocator.alloc([]const u8, slice.len);
    errdefer allocator.free(out);
    for (slice, 0..) |arg, idx| out[idx] = std.mem.span(arg);
    return out;
}

fn isSaxCliError(err: anyerror) bool {
    return switch (err) {
        error.MissingSourcePath,
        error.UnexpectedArgument,
        error.UnknownCommand,
        error.InvalidPath,
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        => true,
        else => false,
    };
}

fn writeSaxCliError(writer: std.io.AnyWriter, argv: []const []const u8, err: anyerror) !void {
    const sub = if (argv.len >= 3) argv[2] else "";
    const message = switch (err) {
        error.MissingSourcePath => "missing required SAX operand",
        error.UnexpectedArgument => "unexpected SAX argument",
        error.UnknownCommand => "unknown SAX subcommand",
        error.InvalidPath => "invalid SAX path",
        error.FileNotFound => "SAX file or directory not found",
        error.NotDir => "SAX path is not a directory",
        error.AccessDenied => "SAX path access denied",
        else => @errorName(err),
    };
    const help = if (err == error.MissingSourcePath and sub.len == 0)
        "usage: sa sax <build|check|dev|new> <file-or-project>"
    else if (std.mem.eql(u8, sub, "build"))
        "usage: sa sax build <file.sax> [--out-dir <dir>]"
    else if (std.mem.eql(u8, sub, "check"))
        "usage: sa sax check <file.sax>"
    else if (std.mem.eql(u8, sub, "dev"))
        "usage: sa sax dev <file.sax> [--out-dir <dir>]"
    else if (std.mem.eql(u8, sub, "new"))
        "usage: sa sax new <project-name>"
    else
        "usage: sa sax <build|check|dev|new> <file-or-project>";
    try writer.print("error[SA-SAX-CLI]: {s}\n  help: {s}\n", .{ message, help });
}

fn saxCliExitCode(err: anyerror) u8 {
    return switch (err) {
        error.UnknownCommand,
        error.MissingSourcePath,
        error.UnexpectedArgument,
        => 2,
        error.InvalidPath,
        error.FileNotFound,
        error.NotDir,
        error.AccessDenied,
        => 3,
        else => 1,
    };
}

fn sourceStem(path: []const u8) []const u8 {
    const basename = std.fs.path.basename(path);
    const dot_idx = std.mem.lastIndexOfScalar(u8, basename, '.') orelse basename.len;
    return basename[0..dot_idx];
}

fn sourceDir(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn lowercaseName(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
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

fn readSource(allocator: std.mem.Allocator, sax_file: []const u8, stderr: std.io.AnyWriter) ![]u8 {
    return std.fs.cwd().readFileAlloc(allocator, sax_file, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        error.IsDir => return error.NotDir,
        else => {
            try stderr.print("error[SA-SAX-IO]: failed to read {s}: {s}\n", .{ sax_file, @errorName(err) });
            return error.InvalidPath;
        },
    };
}

fn sourceUsesWgpu(source: []const u8) bool {
    return std.mem.containsAtLeast(u8, source, 1, "renderer=\"wgpu\"") or
        std.mem.containsAtLeast(u8, source, 1, "sa_wgpu_") or
        std.mem.containsAtLeast(u8, source, 1, "WGPU_CUBE_");
}

fn sourceUsesSa3dPrelude(source: []const u8) bool {
    return std.mem.containsAtLeast(u8, source, 1, "renderer=\"sa3d\"") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_") or
        std.mem.containsAtLeast(u8, source, 1, "SA3D_");
}

fn sourceUsesSa3dAirlock(source: []const u8) bool {
    return std.mem.containsAtLeast(u8, source, 1, "renderer=\"sa3d\"") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_request_context") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_create_shader") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_create_buffer") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_create_cube_pipeline") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_submit_cube_frame") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_request_renderer") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_configure_renderer") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_upload_mesh") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_upload_material") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_render_frame") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_request_frame") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_cancel_frame") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_last_error");
}

fn sourceUsesSa3dRenderWgpu(source: []const u8) bool {
    return std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_request_renderer") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_configure_renderer") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_upload_mesh") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_upload_material") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_render_frame") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_request_frame") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_cancel_frame") or
        std.mem.containsAtLeast(u8, source, 1, "sa3d_wgpu_last_error");
}

fn fileExists(path: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}

fn addOwnedCandidate(candidates: *std.ArrayList([]u8), candidate: []u8) !void {
    errdefer candidates.allocator.free(candidate);
    for (candidates.items) |existing| {
        if (std.mem.eql(u8, existing, candidate)) {
            candidates.allocator.free(candidate);
            return;
        }
    }
    try candidates.append(candidate);
}

fn addEnvDirCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList([]u8), env_name: []const u8) !void {
    const value = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    try addOwnedCandidate(candidates, value);
}

fn addEnvAirlockDirCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList([]u8), env_name: []const u8) !void {
    const value = std.process.getEnvVarOwned(allocator, env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(value);
    const dir = std.fs.path.dirname(value) orelse return;
    try addOwnedCandidate(candidates, try allocator.dupe(u8, dir));
}

fn addShareDirFromPluginLib(allocator: std.mem.Allocator, candidates: *std.ArrayList([]u8), spec: SidecarSpec, lib_path: []const u8) !void {
    const basename = std.fs.path.basename(lib_path);
    if (!std.mem.eql(u8, basename, spec.lib_name) and !std.mem.containsAtLeast(u8, lib_path, 1, spec.path_token)) return;
    const lib_dir = std.fs.path.dirname(lib_path) orelse return;
    try addOwnedCandidate(candidates, try std.fs.path.join(allocator, &.{ lib_dir, "share" }));
    const prefix_dir = std.fs.path.dirname(lib_dir) orelse return;
    try addOwnedCandidate(candidates, try std.fs.path.join(allocator, &.{ prefix_dir, "share" }));
}

fn addInstalledShareCandidate(allocator: std.mem.Allocator, candidates: *std.ArrayList([]u8), spec: SidecarSpec) !void {
    const home = std.process.getEnvVarOwned(allocator, "SA_PLUGINS_HOME") catch |home_err| switch (home_err) {
        error.EnvironmentVariableNotFound => blk: {
            const user_home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => return,
                else => return err,
            };
            defer allocator.free(user_home);
            break :blk try std.fs.path.join(allocator, &.{ user_home, ".local", "share", "sa_plugins" });
        },
        else => return home_err,
    };
    defer allocator.free(home);
    try addOwnedCandidate(candidates, try std.fs.path.join(allocator, &.{ home, "installed", spec.installed_name, "current", "share" }));
}

fn addPluginPathCandidates(allocator: std.mem.Allocator, candidates: *std.ArrayList([]u8), spec: SidecarSpec) !void {
    const value = std.process.getEnvVarOwned(allocator, "SA_PLUGINS_PATH") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return,
        else => return err,
    };
    defer allocator.free(value);

    const separator = if (builtin.os.tag == .windows) ';' else ':';
    var parts = std.mem.splitScalar(u8, value, separator);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try addShareDirFromPluginLib(allocator, candidates, spec, part);
    }
}

fn findSidecarShareDir(allocator: std.mem.Allocator, spec: SidecarSpec) !?[]u8 {
    var candidates = std.ArrayList([]u8).init(allocator);
    defer {
        for (candidates.items) |candidate| allocator.free(candidate);
        candidates.deinit();
    }

    try addEnvDirCandidate(allocator, &candidates, spec.share_env);
    if (spec.share_env_alt) |env_name| try addEnvDirCandidate(allocator, &candidates, env_name);
    try addEnvAirlockDirCandidate(allocator, &candidates, spec.airlock_env);
    try addPluginPathCandidates(allocator, &candidates, spec);
    try addInstalledShareCandidate(allocator, &candidates, spec);
    try addOwnedCandidate(&candidates, try allocator.dupe(u8, spec.dev_share_dir));

    for (candidates.items) |candidate| {
        const sai_path = try std.fs.path.join(allocator, &.{ candidate, spec.sai_file });
        defer allocator.free(sai_path);
        const sal_path = try std.fs.path.join(allocator, &.{ candidate, spec.sal_file });
        defer allocator.free(sal_path);
        var airlock_ok = true;
        if (spec.airlock_file) |airlock_file| {
            const airlock_path = try std.fs.path.join(allocator, &.{ candidate, airlock_file });
            defer allocator.free(airlock_path);
            airlock_ok = fileExists(airlock_path);
        }
        if (fileExists(sai_path) and fileExists(sal_path) and airlock_ok) {
            return try allocator.dupe(u8, candidate);
        }
    }
    return null;
}

fn loadSidecarSupport(allocator: std.mem.Allocator, stderr: std.io.AnyWriter, spec: SidecarSpec) !SidecarSupport {
    const share_dir = (try findSidecarShareDir(allocator, spec)) orelse {
        try stderr.print("error[{s}]: {s} SAX source requires sidecar files; install sa_plugin_{s}, set {s}, or include {s} in SA_PLUGINS_PATH\n", .{
            spec.error_tag,
            spec.label,
            spec.installed_name,
            spec.share_env,
            spec.lib_name,
        });
        return error.SaxCheckFailed;
    };
    defer allocator.free(share_dir);

    const sai_path = try std.fs.path.join(allocator, &.{ share_dir, spec.sai_file });
    defer allocator.free(sai_path);
    const sal_path = try std.fs.path.join(allocator, &.{ share_dir, spec.sal_file });
    defer allocator.free(sal_path);
    const airlock_file = spec.airlock_file orelse return error.SaxCheckFailed;
    const airlock_path = try std.fs.path.join(allocator, &.{ share_dir, airlock_file });
    defer allocator.free(airlock_path);

    const sai = try std.fs.cwd().readFileAlloc(allocator, sai_path, 1024 * 1024);
    defer allocator.free(sai);
    const sal = try std.fs.cwd().readFileAlloc(allocator, sal_path, 4 * 1024 * 1024);
    defer allocator.free(sal);

    var prelude = std.ArrayList(u8).init(allocator);
    errdefer prelude.deinit();
    try prelude.appendSlice(sai);
    if (prelude.items.len == 0 or prelude.items[prelude.items.len - 1] != '\n') try prelude.append('\n');
    try prelude.appendSlice(sal);
    if (prelude.items.len == 0 or prelude.items[prelude.items.len - 1] != '\n') try prelude.append('\n');
    try prelude.append('\n');

    var airlock_js = std.ArrayList(u8).init(allocator);
    errdefer airlock_js.deinit();
    const airlock_bytes = try std.fs.cwd().readFileAlloc(allocator, airlock_path, 4 * 1024 * 1024);
    defer allocator.free(airlock_bytes);
    try airlock_js.appendSlice(airlock_bytes);

    return .{ .prelude = prelude, .airlock_js = airlock_js };
}

fn loadSidecarPrelude(allocator: std.mem.Allocator, stderr: std.io.AnyWriter, spec: SidecarSpec) !std.ArrayList(u8) {
    const share_dir = (try findSidecarShareDir(allocator, spec)) orelse {
        try stderr.print("error[{s}]: {s} SAX source requires sidecar files; install sa_plugin_{s}, set {s}, or include {s} in SA_PLUGINS_PATH\n", .{
            spec.error_tag,
            spec.label,
            spec.installed_name,
            spec.share_env,
            spec.lib_name,
        });
        return error.SaxCheckFailed;
    };
    defer allocator.free(share_dir);

    const sai_path = try std.fs.path.join(allocator, &.{ share_dir, spec.sai_file });
    defer allocator.free(sai_path);
    const sal_path = try std.fs.path.join(allocator, &.{ share_dir, spec.sal_file });
    defer allocator.free(sal_path);

    const sai = try std.fs.cwd().readFileAlloc(allocator, sai_path, 1024 * 1024);
    defer allocator.free(sai);
    const sal = try std.fs.cwd().readFileAlloc(allocator, sal_path, 4 * 1024 * 1024);
    defer allocator.free(sal);

    var prelude = std.ArrayList(u8).init(allocator);
    errdefer prelude.deinit();
    try prelude.appendSlice(sai);
    if (prelude.items.len == 0 or prelude.items[prelude.items.len - 1] != '\n') try prelude.append('\n');
    try prelude.appendSlice(sal);
    if (prelude.items.len == 0 or prelude.items[prelude.items.len - 1] != '\n') try prelude.append('\n');
    try prelude.append('\n');
    return prelude;
}

fn loadSidecarSai(allocator: std.mem.Allocator, stderr: std.io.AnyWriter, spec: SidecarSpec) !std.ArrayList(u8) {
    const share_dir = (try findSidecarShareDir(allocator, spec)) orelse {
        try stderr.print("error[{s}]: {s} SAX source requires interface files; install sa_plugin_{s}, set {s}, or include {s} in SA_PLUGINS_PATH\n", .{
            spec.error_tag,
            spec.label,
            spec.installed_name,
            spec.share_env,
            spec.lib_name,
        });
        return error.SaxCheckFailed;
    };
    defer allocator.free(share_dir);

    const sai_path = try std.fs.path.join(allocator, &.{ share_dir, spec.sai_file });
    defer allocator.free(sai_path);
    const sai = try std.fs.cwd().readFileAlloc(allocator, sai_path, 1024 * 1024);
    defer allocator.free(sai);

    var prelude = std.ArrayList(u8).init(allocator);
    errdefer prelude.deinit();
    try prelude.appendSlice(sai);
    if (prelude.items.len == 0 or prelude.items[prelude.items.len - 1] != '\n') try prelude.append('\n');
    try prelude.append('\n');
    return prelude;
}

fn parseErrorName(err: parser.ParseError) []const u8 {
    return switch (err) {
        parser.ParseError.UnknownTag => "SaxUnknownTag",
        parser.ParseError.UnknownEvent => "SaxUnknownEvent",
        parser.ParseError.InvalidAttribute => "SaxInvalidAttribute",
        parser.ParseError.InvalidNativeEscape => "SaxInvalidNativeEscape",
        else => @errorName(err),
    };
}

fn writeParseError(stderr: std.io.AnyWriter, sax_file: []const u8, err: parser.ParseError) !void {
    try stderr.print("error[SA-SAX-CHECK]: {s} while parsing {s}\n", .{ parseErrorName(err), sax_file });
}

fn validationErrorName(err: ValidationError) []const u8 {
    return switch (err) {
        .SaxStateLeak => "SaxStateLeak",
        .SaxEventEscape => "SaxEventEscape",
        .SaxRenderOutsideHandler => "SaxRenderOutsideHandler",
        .SaxInvalidInterpolation => "SaxInvalidInterpolation",
        .SaxStateWriteFromOutside => "SaxStateWriteFromOutside",
        .SaxInvalidNativeEscape => "SaxInvalidNativeEscape",
    };
}

fn writeValidationFailure(stderr: std.io.AnyWriter, failure: ValidationFailure) !void {
    try stderr.print("error[SA-SAX-CHECK]: {s} in component {s}", .{
        validationErrorName(failure.err),
        failure.component_name,
    });
    if (failure.line != 0) try stderr.print(" at line {d}", .{failure.line});
    try stderr.writeByte('\n');
    if (failure.text.len != 0) try stderr.print("  source: {s}\n", .{failure.text});
}

fn sourceLineAt(source: []const u8, wanted_line: u32) []const u8 {
    if (wanted_line == 0) return "";
    var line_no: u32 = 1;
    var start: usize = 0;
    var idx: usize = 0;
    while (idx <= source.len) : (idx += 1) {
        if (idx == source.len or source[idx] == '\n') {
            if (line_no == wanted_line) return std.mem.trimRight(u8, source[start..idx], "\r");
            line_no += 1;
            start = idx + 1;
        }
    }
    return "";
}

fn writeSlaHandlerCompileFailure(
    stderr: std.io.AnyWriter,
    sax_file: []const u8,
    source: []const u8,
    failure: lowerer.SlaHandlerCompileFailure,
) !void {
    try stderr.print(
        "error[SAX_HANDLER_COMPILE_FAIL]: {s} while compiling Sla handler {s}.{s} at {s}:{d}\n",
        .{ failure.err_name, failure.component_name, failure.handler_name, sax_file, failure.line },
    );
    const line = sourceLineAt(source, failure.line);
    if (line.len != 0) try stderr.print("  {s}\n", .{line});
}

fn hasNativeEscape(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len >= 2 and trimmed[0] == '$' and trimmed[trimmed.len - 1] == '$') return true;
    }
    return false;
}

fn findEventHandler(component: parser.Component, handler_name: []const u8) bool {
    for (component.handlers) |handler| {
        if (std.mem.eql(u8, handler.name, handler_name)) return true;
    }
    return false;
}

fn componentHasSlaHandlers(component: parser.Component) bool {
    for (component.handlers) |handler| {
        if (handler.language == .sla) return true;
    }
    return false;
}

fn interpolationIsInvalid(expr: parser.Expr) bool {
    return std.mem.indexOfAny(u8, expr.expr, "^!") != null;
}

fn findValidationFailure(allocator: std.mem.Allocator, component: parser.Component) ?ValidationFailure {
    var released = std.StringHashMap(void).init(allocator);
    defer released.deinit();
    for (component.release_vars) |name| released.put(name, {}) catch return null;

    for (component.state_vars) |sv| {
        if (!componentHasSlaHandlers(component) and !released.contains(sv.name)) {
            return .{ .component_name = component.name, .err = .SaxStateLeak, .line = 1, .text = sv.name };
        }
    }

    for (component.dom_nodes) |node| {
        for (node.attrs) |attr| {
            if (attr.is_event) {
                const handler_name = attr.event_handler orelse {
                    return .{ .component_name = component.name, .err = .SaxEventEscape, .line = 1, .text = attr.name };
                };
                if (!findEventHandler(component, handler_name)) {
                    return .{ .component_name = component.name, .err = .SaxEventEscape, .line = 1, .text = handler_name };
                }
            }
            switch (attr.value) {
                .literal => {},
                .interpolation => |expr| if (interpolationIsInvalid(expr)) {
                    return .{ .component_name = component.name, .err = .SaxInvalidInterpolation, .line = 1, .text = expr.expr };
                },
            }
        }
        for (node.children) |child| {
            switch (child) {
                .text => |piece| switch (piece) {
                    .text => {},
                    .interpolation => |expr| if (interpolationIsInvalid(expr)) {
                        return .{ .component_name = component.name, .err = .SaxInvalidInterpolation, .line = 1, .text = expr.expr };
                    },
                },
                .node_index => {},
            }
        }
    }

    for (component.orphan_lines) |line| {
        if (hasNativeEscape(line.text)) {
            return .{ .component_name = component.name, .err = .SaxInvalidNativeEscape, .line = line.line, .text = line.text };
        }
        if (std.mem.containsAtLeast(u8, line.text, 1, "call @render()")) {
            return .{ .component_name = component.name, .err = .SaxRenderOutsideHandler, .line = line.line, .text = line.text };
        }
        if (std.mem.containsAtLeast(u8, line.text, 1, "store state+")) {
            return .{ .component_name = component.name, .err = .SaxStateWriteFromOutside, .line = line.line, .text = line.text };
        }
    }

    for (component.handlers) |handler| {
        if (!handler.is_ffi_wrapper and hasNativeEscape(handler.body)) {
            return .{ .component_name = component.name, .err = .SaxInvalidNativeEscape, .line = 1, .text = handler.body };
        }
    }
    for (component.lifecycle_hooks) |hook| {
        if (!hook.is_ffi_wrapper and hasNativeEscape(hook.body)) {
            return .{ .component_name = component.name, .err = .SaxInvalidNativeEscape, .line = 1, .text = hook.body };
        }
    }

    return null;
}

fn compileSaxArtifacts(
    allocator: std.mem.Allocator,
    sax_file: []const u8,
    source: []const u8,
    stderr: std.io.AnyWriter,
) !SaxArtifacts {
    var sax_parser = parser.SaxParser.init(allocator, source);
    var program = sax_parser.parse() catch |err| {
        try writeParseError(stderr, sax_file, err);
        return error.SaxCheckFailed;
    };
    defer program.deinit();

    if (program.components.len == 0) {
        try stderr.print("error[SA-SAX-CHECK]: InvalidComponentBody while parsing {s}\n", .{sax_file});
        return error.SaxCheckFailed;
    }

    for (program.components) |component| {
        if (findValidationFailure(allocator, component)) |failure| {
            try writeValidationFailure(stderr, failure);
            return error.SaxCheckFailed;
        }
    }

    const uses_wgpu = sourceUsesWgpu(source);
    const uses_sa3d_prelude = sourceUsesSa3dPrelude(source);
    const uses_sa3d_airlock = sourceUsesSa3dAirlock(source);
    const needs_wgpu_prelude = uses_wgpu and !uses_sa3d_prelude;
    var wgpu_airlock_js: ?std.ArrayList(u8) = null;
    errdefer if (wgpu_airlock_js) |*js| js.deinit();
    var sa3d_airlock_js: ?std.ArrayList(u8) = null;
    errdefer if (sa3d_airlock_js) |*js| js.deinit();

    var sa_code = std.ArrayList(u8).init(allocator);
    errdefer sa_code.deinit();
    if (needs_wgpu_prelude) {
        var wgpu_support = try loadSidecarSupport(allocator, stderr, wgpu_sidecar);
        defer wgpu_support.prelude.deinit();
        try sa_code.appendSlice(wgpu_support.prelude.items);
        wgpu_airlock_js = wgpu_support.airlock_js;
    }
    if (uses_wgpu and !needs_wgpu_prelude) {
        const share_dir = (try findSidecarShareDir(allocator, wgpu_sidecar)) orelse {
            try stderr.print("error[{s}]: {s} SAX source requires sidecar files; install sa_plugin_{s}, set {s}, or include {s} in SA_PLUGINS_PATH\n", .{
                wgpu_sidecar.error_tag,
                wgpu_sidecar.label,
                wgpu_sidecar.installed_name,
                wgpu_sidecar.share_env,
                wgpu_sidecar.lib_name,
            });
            return error.SaxCheckFailed;
        };
        defer allocator.free(share_dir);

        const airlock_file = wgpu_sidecar.airlock_file orelse return error.SaxCheckFailed;
        const airlock_path = try std.fs.path.join(allocator, &.{ share_dir, airlock_file });
        defer allocator.free(airlock_path);
        const airlock_bytes = try std.fs.cwd().readFileAlloc(allocator, airlock_path, 4 * 1024 * 1024);
        defer allocator.free(airlock_bytes);

        var airlock_js = std.ArrayList(u8).init(allocator);
        errdefer airlock_js.deinit();
        try airlock_js.appendSlice(airlock_bytes);
        wgpu_airlock_js = airlock_js;
    }
    if (uses_sa3d_prelude) {
        if (sourceUsesSa3dRenderWgpu(source)) {
            var render_wgpu_imports = try loadSidecarSai(allocator, stderr, sa3d_render_wgpu_sidecar);
            defer render_wgpu_imports.deinit();
            try sa_code.appendSlice(render_wgpu_imports.items);
        }
        if (uses_sa3d_airlock) {
            var sa3d_support = try loadSidecarSupport(allocator, stderr, sa3d_sidecar);
            defer sa3d_support.prelude.deinit();
            try sa_code.appendSlice(sa3d_support.prelude.items);
            sa3d_airlock_js = sa3d_support.airlock_js;
        } else {
            var sa3d_prelude = try loadSidecarPrelude(allocator, stderr, sa3d_sidecar);
            defer sa3d_prelude.deinit();
            try sa_code.appendSlice(sa3d_prelude.items);
        }
    }
    for (program.components, 0..) |component, idx| {
        var sax_lowerer = try lowerer.SaxLowerer.init(allocator, component);
        defer sax_lowerer.deinit();
        sax_lowerer.lower(&sa_code, .{ .emit_shared_decls = idx == 0, .sla_base_dir = sourceDir(sax_file) }) catch |err| switch (err) {
            lowerer.LowerError.SlaHandlerCompileFailed => {
                if (sax_lowerer.slaHandlerCompileFailure()) |failure| {
                    try writeSlaHandlerCompileFailure(stderr, sax_file, source, failure);
                    return error.SaxCheckFailed;
                }
                return err;
            },
            else => return err,
        };
        if (idx + 1 < program.components.len) try sa_code.writer().writeByte('\n');
    }

    const root_name = try lowercaseName(allocator, program.components[0].name);
    errdefer allocator.free(root_name);
    try sa_code.writer().print("@export sax_app_init() -> ptr:\nL_ENTRY:\n  ctx = call @sax_{s}_init()\n  return ctx\n\n", .{root_name});

    var airlock_generator = airlock_gen.AirlockGenerator.init(allocator);
    const airlock_js = try airlock_generator.generateAirlockJSWithOptions(.{ .wgpu = uses_wgpu, .sa3d = uses_sa3d_airlock });
    errdefer airlock_js.deinit();

    const index_html = try airlock_generator.generateIndexHTML(sourceStem(sax_file), "app.wasm");
    errdefer index_html.deinit();

    return .{
        .component_name = sourceStem(sax_file),
        .root_name = root_name,
        .sa_code = sa_code,
        .airlock_js = airlock_js,
        .wgpu_airlock_js = wgpu_airlock_js,
        .sa3d_airlock_js = sa3d_airlock_js,
        .index_html = index_html,
    };
}

fn parseOutDir(argv: []const []const u8, start: usize) !?[]const u8 {
    var out_dir: ?[]const u8 = null;
    var i = start;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--out-dir") or std.mem.eql(u8, argv[i], "-o")) {
            if (i + 1 >= argv.len) return error.MissingSourcePath;
            if (out_dir != null) return error.UnexpectedArgument;
            out_dir = argv[i + 1];
            i += 1;
            continue;
        }
        return error.UnexpectedArgument;
    }
    return out_dir;
}

fn executeSaxCheck(
    ctx: *const plugin_api.Context,
    sax_file: []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    const source = try readSource(ctx.allocator, sax_file, stderr);
    defer ctx.allocator.free(source);
    var artifacts = compileSaxArtifacts(ctx.allocator, sax_file, source, stderr) catch |err| switch (err) {
        error.SaxCheckFailed => return 1,
        else => return err,
    };
    defer artifacts.deinit(ctx.allocator);

    const verified = try sax_build.compileSourceText(ctx.allocator, sax_file, artifacts.sa_code.items, .{});
    switch (verified) {
        .trap => |report| {
            try sax_build.printTrapReport(stderr, report);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(ctx.allocator);
        },
    }

    try stdout.print("SAX check passed: {s}\n", .{sax_file});
    return 0;
}

fn executeSaxBuild(
    ctx: *const plugin_api.Context,
    sax_file: []const u8,
    out_dir: []const u8,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) !u8 {
    const source = try readSource(ctx.allocator, sax_file, stderr);
    defer ctx.allocator.free(source);
    var artifacts = compileSaxArtifacts(ctx.allocator, sax_file, source, stderr) catch |err| switch (err) {
        error.SaxCheckFailed => return 1,
        else => return err,
    };
    defer artifacts.deinit(ctx.allocator);

    const sa_path = try std.fs.path.join(ctx.allocator, &.{ out_dir, "app.sa" });
    defer ctx.allocator.free(sa_path);
    const airlock_path = try std.fs.path.join(ctx.allocator, &.{ out_dir, "airlock.js" });
    defer ctx.allocator.free(airlock_path);
    const wgpu_airlock_path = try std.fs.path.join(ctx.allocator, &.{ out_dir, "wgpu_airlock.js" });
    defer ctx.allocator.free(wgpu_airlock_path);
    const sa3d_airlock_path = try std.fs.path.join(ctx.allocator, &.{ out_dir, "sa3d_airlock.js" });
    defer ctx.allocator.free(sa3d_airlock_path);
    const html_path = try std.fs.path.join(ctx.allocator, &.{ out_dir, "index.html" });
    defer ctx.allocator.free(html_path);
    const wasm_path = try std.fs.path.join(ctx.allocator, &.{ out_dir, "app.wasm" });
    defer ctx.allocator.free(wasm_path);

    try writeAllFile(sa_path, artifacts.sa_code.items);

    const build_code = try sax_build.buildBrowserWasmFromSourceText(
        ctx.allocator,
        sa_path,
        artifacts.sa_code.items,
        wasm_path,
        false,
        .release_small,
        .{},
        stderr,
    );
    if (build_code != 0) return build_code;

    try writeAllFile(airlock_path, artifacts.airlock_js.items);
    if (artifacts.wgpu_airlock_js) |*wgpu_js| {
        try writeAllFile(wgpu_airlock_path, wgpu_js.items);
    }
    if (artifacts.sa3d_airlock_js) |*sa3d_js| {
        try writeAllFile(sa3d_airlock_path, sa3d_js.items);
    }
    try writeAllFile(html_path, artifacts.index_html.items);

    try stdout.print("SAX build successful\n", .{});
    try stdout.print("  app.sa: {s}\n", .{sa_path});
    try stdout.print("  app.wasm: {s}\n", .{wasm_path});
    try stdout.print("  airlock.js: {s}\n", .{airlock_path});
    if (artifacts.wgpu_airlock_js != null) try stdout.print("  wgpu_airlock.js: {s}\n", .{wgpu_airlock_path});
    if (artifacts.sa3d_airlock_js != null) try stdout.print("  sa3d_airlock.js: {s}\n", .{sa3d_airlock_path});
    try stdout.print("  index.html: {s}\n", .{html_path});
    return 0;
}

fn executeSaxNew(ctx: *const plugin_api.Context, project_name: []const u8, stdout: std.io.AnyWriter) !u8 {
    try std.fs.cwd().makePath(project_name);

    const sax_template =
        \\<Component name="App">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\  <div class="app">
        \\    <h1>Hello SAX</h1>
        \\    <p>Count: {count}</p>
        \\    <button onclick={^increment}>+1</button>
        \\  </div>
        \\  @increment:
        \\  L_ENTRY:
        \\    count = load state+App_count as i64
        \\    count = add count, 1
        \\    store state+App_count, count as i64
        \\    call @render()
        \\    ret
        \\  !count
        \\</Component>
        \\
    ;

    const sax_path = try std.fs.path.join(ctx.allocator, &.{ project_name, "app.sax" });
    defer ctx.allocator.free(sax_path);
    try writeAllFile(sax_path, sax_template);

    const readme_path = try std.fs.path.join(ctx.allocator, &.{ project_name, "README.md" });
    defer ctx.allocator.free(readme_path);
    const readme = try std.fmt.allocPrint(ctx.allocator,
        \\# {s}
        \\
        \\SAX project scaffold.
        \\
        \\```bash
        \\sa sax check app.sax
        \\sa sax build app.sax
        \\```
        \\
    , .{project_name});
    defer ctx.allocator.free(readme);
    try writeAllFile(readme_path, readme);

    const package_path = try std.fs.path.join(ctx.allocator, &.{ project_name, "package.json" });
    defer ctx.allocator.free(package_path);
    const package_json = try std.fmt.allocPrint(ctx.allocator,
        \\{{
        \\  "name": "{s}",
        \\  "private": true,
        \\  "type": "module",
        \\  "scripts": {{
        \\    "check": "sa sax check app.sax",
        \\    "build": "sa sax build app.sax",
        \\    "dev": "sa sax dev app.sax"
        \\  }}
        \\}}
        \\
    , .{project_name});
    defer ctx.allocator.free(package_json);
    try writeAllFile(package_path, package_json);

    try stdout.print("SAX project created: {s}\n", .{project_name});
    try stdout.print("  app.sax: {s}\n", .{sax_path});
    try stdout.print("  README.md: {s}\n", .{readme_path});
    try stdout.print("  package.json: {s}\n", .{package_path});
    return 0;
}

fn runSaxCommandImpl(ctx: *const plugin_api.Context, argv: []const []const u8, stdout: std.io.AnyWriter, stderr: std.io.AnyWriter) anyerror!?u8 {
    if (argv.len < 2) return null;
    if (!std.mem.eql(u8, argv[1], "sax")) return null;
    if (argv.len < 3) return error.MissingSourcePath;

    const sub = argv[2];
    if (std.mem.eql(u8, sub, "build")) {
        if (argv.len < 4) return error.MissingSourcePath;
        const out_dir = (try parseOutDir(argv, 4)) orelse "dist";
        return try executeSaxBuild(ctx, argv[3], out_dir, stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "check")) {
        if (argv.len != 4) return if (argv.len < 4) error.MissingSourcePath else error.UnexpectedArgument;
        return try executeSaxCheck(ctx, argv[3], stdout, stderr);
    }
    if (std.mem.eql(u8, sub, "dev")) {
        if (argv.len < 4) return error.MissingSourcePath;
        const out_dir = (try parseOutDir(argv, 4)) orelse "dist";
        const code = try executeSaxBuild(ctx, argv[3], out_dir, stdout, stderr);
        if (code == 0) try stdout.print("SAX dev artifacts refreshed in {s}\n", .{out_dir});
        return code;
    }
    if (std.mem.eql(u8, sub, "new")) {
        if (argv.len != 4) return if (argv.len < 4) error.MissingSourcePath else error.UnexpectedArgument;
        return try executeSaxNew(ctx, argv[3], stdout);
    }
    return error.UnknownCommand;
}

fn anyWriterFromHostStream(stream: plugin_api.HostStream, storage: *plugin_api.HostStream) std.io.AnyWriter {
    storage.* = stream;
    return .{ .context = storage, .writeFn = struct {
        fn write(ctx: *const anyopaque, bytes: []const u8) anyerror!usize {
            const hs = @as(*const plugin_api.HostStream, @ptrCast(@alignCast(ctx)));
            const write_all = hs.write_all orelse return error.WriteFailed;
            if (write_all(hs.ctx, bytes.ptr, bytes.len) != @intFromEnum(plugin_api.AbiStatus.ok)) return error.WriteFailed;
            return bytes.len;
        }
    }.write };
}

fn runSaxCommandAbi(ctx: *const plugin_api.Context, argv: [*]const [*:0]const u8, argv_len: usize, stdout: plugin_api.HostStream, stderr: plugin_api.HostStream, out_code: *u8) callconv(.c) u32 {
    out_code.* = 0;
    const allocator = std.heap.page_allocator;
    var local_ctx = ctx.*;
    local_ctx.allocator = allocator;
    const args = cArgvToSlice(argv, argv_len, allocator) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    defer allocator.free(args);

    var stdout_storage = stdout;
    var stderr_storage = stderr;
    const stdout_writer = anyWriterFromHostStream(stdout, &stdout_storage);
    const stderr_writer = anyWriterFromHostStream(stderr, &stderr_storage);

    const result = runSaxCommandImpl(&local_ctx, args, stdout_writer, stderr_writer) catch |err| {
        if (!isSaxCliError(err)) return @intFromEnum(plugin_api.AbiStatus.failed);
        writeSaxCliError(stderr_writer, args, err) catch return @intFromEnum(plugin_api.AbiStatus.failed);
        out_code.* = saxCliExitCode(err);
        return @intFromEnum(plugin_api.AbiStatus.ok);
    };
    if (result) |code| {
        out_code.* = code;
        return @intFromEnum(plugin_api.AbiStatus.ok);
    }
    return @intFromEnum(plugin_api.AbiStatus.unknown_command);
}

const descriptor = plugin_api.PluginDescriptor{
    .abi_version = plugin_api.abi_version,
    .descriptor_size = @as(u32, @intCast(@sizeOf(plugin_api.PluginDescriptor))),
    .name = "sax",
    .init = null,
    .prebuild = null,
    .postbuild = null,
    .handle_command = runSaxCommandAbi,
    .skills_ptr = skills[0..].ptr,
    .skills_len = skills.len,
};

pub export const saasm_plugin_descriptor_v1: plugin_api.PluginDescriptor = descriptor;
pub export fn saasm_plugin_descriptor_v1_fn(out: *plugin_api.PluginDescriptor) callconv(.c) void {
    out.* = descriptor;
}

const CaptureStream = struct {
    buffer: *std.ArrayList(u8),
};

fn captureWriteAll(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) u32 {
    const stream = @as(*CaptureStream, @ptrCast(@alignCast(ctx orelse return @intFromEnum(plugin_api.AbiStatus.failed))));
    stream.buffer.appendSlice(bytes[0..len]) catch return @intFromEnum(plugin_api.AbiStatus.failed);
    return @intFromEnum(plugin_api.AbiStatus.ok);
}

fn captureHostStream(ctx: *CaptureStream) plugin_api.HostStream {
    return .{ .ctx = ctx, .write_all = captureWriteAll };
}

fn dupeZArgs(allocator: std.mem.Allocator, argv: []const []const u8) ![][*:0]const u8 {
    var out = try allocator.alloc([*:0]const u8, argv.len);
    errdefer allocator.free(out);
    var copied: usize = 0;
    errdefer {
        for (out[0..copied]) |arg| allocator.free(std.mem.sliceTo(arg, 0));
    }
    for (argv, 0..) |arg, idx| {
        out[idx] = try allocator.dupeZ(u8, arg);
        copied += 1;
    }
    return out;
}

fn freeZArgs(allocator: std.mem.Allocator, argv: [][*:0]const u8) void {
    for (argv) |arg| allocator.free(std.mem.sliceTo(arg, 0));
    allocator.free(argv);
}

fn invokeForTest(argv: []const []const u8, stdout_buffer: *std.ArrayList(u8), stderr_buffer: *std.ArrayList(u8), allocator: std.mem.Allocator) !u8 {
    var ctx = plugin_api.Context{ .allocator = allocator };
    var stdout_ctx = CaptureStream{ .buffer = stdout_buffer };
    var stderr_ctx = CaptureStream{ .buffer = stderr_buffer };
    const c_argv = try dupeZArgs(allocator, argv);
    defer freeZArgs(allocator, c_argv);
    var out_code: u8 = 255;
    const status = runSaxCommandAbi(&ctx, c_argv.ptr, c_argv.len, captureHostStream(&stdout_ctx), captureHostStream(&stderr_ctx), &out_code);
    try std.testing.expectEqual(@as(u32, @intFromEnum(plugin_api.AbiStatus.ok)), status);
    return out_code;
}

const valid_counter_sax =
    \\<Component name="Counter">
    \\  <state>
    \\    count = 0
    \\  </state>
    \\  <div class="counter">
    \\    <p>{count}</p>
    \\    <button onclick={^inc}>+1</button>
    \\  </div>
    \\  @inc:
    \\  L_ENTRY:
    \\    count = load state+Counter_count as i64
    \\    count = add count, 1
    \\    store state+Counter_count, count as i64
    \\    call @render()
    \\    ret
    \\  !count
    \\</Component>
    \\
;

fn expectSaxCheckFailure(source: []const u8, file_name: []const u8, expected_error: []const u8) !void {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    try writeAllFile(file_name, source);
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try invokeForTest(&.{ "sa", "sax", "check", file_name }, &stdout_buf, &stderr_buf, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, expected_error));
}

fn expectSaxCliFailure(argv: []const []const u8, expected_code: u8, expected_error: []const u8) !void {
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try invokeForTest(argv, &stdout_buf, &stderr_buf, std.testing.allocator);
    try std.testing.expectEqual(expected_code, code);
    try std.testing.expectEqual(@as(usize, 0), stdout_buf.items.len);
    try std.testing.expect(std.mem.containsAtLeast(u8, stderr_buf.items, 1, expected_error));
}

test "sax plugin exports runtime descriptor" {
    try std.testing.expectEqualStrings("sax", std.mem.span(descriptor.name));
    try std.testing.expectEqual(@as(usize, 1), descriptor.skills_len);
}

test "sax plugin abi maps missing build file to usage exit code" {
    try expectSaxCliFailure(&.{ "sa", "sax", "build" }, 2, "error[SA-SAX-CLI]: missing required SAX operand");
}

test "sax plugin abi maps unknown subcommands to usage exit code" {
    try expectSaxCliFailure(&.{ "sa", "sax", "unknown" }, 2, "error[SA-SAX-CLI]: unknown SAX subcommand");
}

test "sax plugin abi maps missing source files to io exit code" {
    try expectSaxCliFailure(&.{ "sa", "sax", "check", "missing.sax" }, 3, "error[SA-SAX-CLI]: SAX file or directory not found");
}

test "sax plugin check parses and lowers a real component" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    try writeAllFile("counter.sax", valid_counter_sax);
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try invokeForTest(&.{ "sa", "sax", "check", "counter.sax" }, &stdout_buf, &stderr_buf, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "SAX check passed"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile("dist/app.sa", .{}));
}

test "sax plugin check accepts mixed sa and sla handlers" {
    const mixed_source =
        \\<Component name="Mixed">
        \\  <state>
        \\    count: i64 = 0
        \\    last: i64 = 0
        \\  </state>
        \\  <section><h1>{count}</h1><button onclick={^inc}>+1</button><button onclick={^reset}>Reset</button></section>
        \\  fn inc() {
        \\    count = count + 1;
        \\    last = sax_get_time();
        \\    render();
        \\  }
        \\  @reset:
        \\  L_ENTRY:
        \\    store state+Mixed_count, 0 as i64
        \\    call @render()
        \\    ret
        \\</Component>
        \\
    ;

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    try writeAllFile("mixed.sax", mixed_source);
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try invokeForTest(&.{ "sa", "sax", "check", "mixed.sax" }, &stdout_buf, &stderr_buf, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "SAX check passed"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sax plugin check resolves sla handler imports relative to sax file" {
    const imported_source =
        \\<Component name="Imported">
        \\  <state>
        \\    count: i64 = 0
        \\  </state>
        \\  <section><h1>{count}</h1><button onclick={^inc}>+1</button></section>
        \\  @import "helpers.sla"
        \\  fn inc() {
        \\    count = add_two(count);
        \\    render();
        \\  }
        \\</Component>
        \\
    ;
    const helper_source =
        \\fn add_two(value: i64) -> i64 {
        \\  return value + 2;
        \\}
        \\
    ;

    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};
    try std.fs.cwd().makePath("pages");

    try writeAllFile("pages/imported.sax", imported_source);
    try writeAllFile("pages/helpers.sla", helper_source);
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try invokeForTest(&.{ "sa", "sax", "check", "pages/imported.sax" }, &stdout_buf, &stderr_buf, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "SAX check passed"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);
}

test "sax plugin check reports sla handler compile failures with source location" {
    const invalid_source =
        \\<Component name="BadSla">
        \\  <state>
        \\    count: i64 = 0
        \\  </state>
        \\  <section><button onclick={^inc}>+1</button></section>
        \\  fn inc() {
        \\    count = missing_name + 1;
        \\    render();
        \\  }
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(invalid_source, "bad_sla.sax", "SAX_HANDLER_COMPILE_FAIL");
    try expectSaxCheckFailure(invalid_source, "bad_sla.sax", "BadSla.inc");
    try expectSaxCheckFailure(invalid_source, "bad_sla.sax", "bad_sla.sax:6");
}

test "sax plugin build emits frontend artifacts from real sax source" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    try writeAllFile("counter.sax", valid_counter_sax);
    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try invokeForTest(&.{ "sa", "sax", "build", "counter.sax", "--out-dir", "public" }, &stdout_buf, &stderr_buf, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "SAX build successful"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, stdout_buf.items, 1, "sax build:"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    const sa = try std.fs.cwd().readFileAlloc(std.testing.allocator, "public/app.sa", 2 * 1024 * 1024);
    defer std.testing.allocator.free(sa);
    try std.testing.expect(std.mem.containsAtLeast(u8, sa, 1, "@export sax_counter_init()"));
    try std.testing.expect(std.mem.containsAtLeast(u8, sa, 1, "@export sax_app_init()"));

    const airlock = try std.fs.cwd().readFileAlloc(std.testing.allocator, "public/airlock.js", 2 * 1024 * 1024);
    defer std.testing.allocator.free(airlock);
    try std.testing.expect(std.mem.containsAtLeast(u8, airlock, 1, "export const sax_airlock"));
    try std.testing.expect(std.mem.containsAtLeast(u8, airlock, 1, "const SAX_WGPU_REQUIRED = false;"));
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().openFile("public/wgpu_airlock.js", .{}));

    const html = try std.fs.cwd().readFileAlloc(std.testing.allocator, "public/index.html", 2 * 1024 * 1024);
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.containsAtLeast(u8, html, 1, "Content-Security-Policy"));

    const wasm = try std.fs.cwd().readFileAlloc(std.testing.allocator, "public/app.wasm", 1024);
    defer std.testing.allocator.free(wasm);
    try std.testing.expect(wasm.len > 8);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 'a', 's', 'm', 0x01, 0x00, 0x00, 0x00 }, wasm[0..8]);
}

test "sax plugin check reports state leaks" {
    const leak_source =
        \\<Component name="Counter">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\  <p>{count}</p>
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(leak_source, "leak.sax", "SaxStateLeak");
}

test "sax plugin check reports event handler escapes" {
    const escape_source =
        \\<Component name="Counter">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\  <button onclick={^missing}>+1</button>
        \\  !count
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(escape_source, "event_escape.sax", "SaxEventEscape");
}

test "sax plugin check rejects affine operators in interpolation" {
    const invalid_source =
        \\<Component name="Counter">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\  <p>{count + ^x}</p>
        \\  !count
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(invalid_source, "invalid_interpolation.sax", "SaxInvalidInterpolation");
}

test "sax plugin check rejects render calls outside handlers" {
    const invalid_source =
        \\<Component name="Counter">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\  <p>{count}</p>
        \\  !count
        \\  call @render()
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(invalid_source, "render_outside_handler.sax", "SaxRenderOutsideHandler");
}

test "sax plugin check rejects state writes outside component handlers" {
    const invalid_source =
        \\<Component name="Counter">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\  <p>{count}</p>
        \\  !count
        \\  store state+Counter_count, 1 as i64
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(invalid_source, "state_write_outside.sax", "SaxStateWriteFromOutside");
}

test "sax plugin check rejects unknown DOM tags" {
    const unknown_tag_source =
        \\<Component name="Counter">
        \\  <foo>bad</foo>
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(unknown_tag_source, "unknown_tag.sax", "SaxUnknownTag");
}

test "sax plugin check rejects unknown DOM events" {
    const unknown_event_source =
        \\<Component name="Counter">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\  <button onhover={^inc}>+1</button>
        \\  @inc:
        \\  L_ENTRY:
        \\    ret
        \\  !count
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(unknown_event_source, "unknown_event.sax", "SaxUnknownEvent");
}

test "sax plugin check rejects DOM attrs outside the whitelist" {
    const unsafe_source =
        \\<Component name="Unsafe">
        \\  <div href="javascript:alert(1)"></div>
        \\</Component>
        \\
    ;
    try expectSaxCheckFailure(unsafe_source, "unsafe_attr.sax", "SaxInvalidAttribute");
}

test "sax plugin new creates a usable project scaffold" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try invokeForTest(&.{ "sa", "sax", "new", "demo" }, &stdout_buf, &stderr_buf, std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.containsAtLeast(u8, stdout_buf.items, 1, "SAX project created"));
    try std.testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    const app = try std.fs.cwd().readFileAlloc(std.testing.allocator, "demo/app.sax", 1024 * 1024);
    defer std.testing.allocator.free(app);
    try std.testing.expect(std.mem.containsAtLeast(u8, app, 1, "<Component name=\"App\">"));

    const package_json = try std.fs.cwd().readFileAlloc(std.testing.allocator, "demo/package.json", 1024 * 1024);
    defer std.testing.allocator.free(package_json);
    try std.testing.expect(std.mem.containsAtLeast(u8, package_json, 1, "\"build\": \"sa sax build app.sax\""));
}
