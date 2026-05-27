// SAX CLI 命令集成
// 负责 build/check/new/dev 子命令

const std = @import("std");
const Allocator = std.mem.Allocator;

const sax = @import("mod.zig");
const sax_build = @import("build.zig");
const parser = @import("parser.zig");
const builtin = @import("builtin");
const trap = if (builtin.is_test) @import("common/trap.zig") else @import("../common/trap.zig");
const plugin_mode = @hasDecl(@import("root"), "plugin_mode") and @import("root").plugin_mode;

pub const SaxCommand = enum {
    build,
    check,
    dev,
    new_project,
};

pub fn parseSaxCommand(cmd_str: []const u8) ?SaxCommand {
    if (std.mem.eql(u8, cmd_str, "build")) return .build;
    if (std.mem.eql(u8, cmd_str, "check")) return .check;
    if (std.mem.eql(u8, cmd_str, "dev")) return .dev;
    if (std.mem.eql(u8, cmd_str, "new")) return .new_project;
    return null;
}

const SaxArtifacts = struct {
    sa_code: std.ArrayList(u8),
    airlock_js: std.ArrayList(u8),
    index_html: std.ArrayList(u8),
};

const SaxCompilation = struct {
    component_name: []const u8,
    artifacts: SaxArtifacts,
};

const SaxValidationError = error{
    SaxStateLeak,
    SaxEventEscape,
    SaxRenderOutsideHandler,
    SaxInvalidInterpolation,
    SaxStateWriteFromOutside,
    SaxInvalidNativeEscape,
    SaxUnknownTag,
    SaxUnknownEvent,
};

const SaxValidationTrap = struct {
    component_name: []const u8,
    err: SaxValidationError,
    line: u32,
    text: []const u8,
};

fn trapKind(err: SaxValidationError) trap.Trap {
    return switch (err) {
        SaxValidationError.SaxStateLeak => .sax_state_leak,
        SaxValidationError.SaxEventEscape => .sax_event_escape,
        SaxValidationError.SaxRenderOutsideHandler => .sax_render_outside_handler,
        SaxValidationError.SaxInvalidInterpolation => .sax_invalid_interpolation,
        SaxValidationError.SaxStateWriteFromOutside => .sax_state_write_from_outside,
        SaxValidationError.SaxInvalidNativeEscape => .forbidden_syntax,
        SaxValidationError.SaxUnknownTag => .sax_unknown_tag,
        SaxValidationError.SaxUnknownEvent => .sax_unknown_event,
    };
}

fn validationMessage(err: SaxValidationError) []const u8 {
    return switch (err) {
        SaxValidationError.SaxStateLeak => "state variable not released at component end",
        SaxValidationError.SaxEventEscape => "handler is not defined in this <Component>",
        SaxValidationError.SaxRenderOutsideHandler => "call @render() is only legal inside @handler",
        SaxValidationError.SaxInvalidInterpolation => "interpolation must not contain ^ or !",
        SaxValidationError.SaxStateWriteFromOutside => "state slot written from outside component",
        SaxValidationError.SaxInvalidNativeEscape => "$...$ native escape is only legal inside @ffi_wrapper",
        SaxValidationError.SaxUnknownTag => "tag is not in the SAX whitelist",
        SaxValidationError.SaxUnknownEvent => "event is not in the SAX whitelist",
    };
}

fn trapReport(info: SaxValidationTrap) trap.TrapReport {
    return .{
        .trap = trapKind(info.err),
        .trap_code = trap.trapCode(trapKind(info.err)),
        .line = info.line,
        .source_line = info.line,
        .source_text = info.text,
        .original_text = info.text,
        .register = null,
        .registers = &.{},
        .expected_mask = null,
        .actual_mask = null,
        .expected_mask_name = null,
        .actual_mask_name = null,
        .upstream_loc = null,
        .upstream_line = 0,
        .upstream_col = 0,
        .function = info.component_name,
        .is_ffi_wrapper = null,
        .message = validationMessage(info.err),
        .hint = null,
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

fn sourceDirAbs(allocator: Allocator, path: []const u8) ![]const u8 {
    return try std.fs.cwd().realpathAlloc(allocator, sourceDir(path));
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

fn readSource(allocator: Allocator, sax_file: []const u8, stderr: anytype) ![]u8 {
    const source = std.fs.cwd().readFileAlloc(allocator, sax_file, 16 * 1024 * 1024) catch |err| {
        try stderr.print("error: failed to read {s}: {}\n", .{ sax_file, err });
        return error.ReadFailed;
    };
    return source;
}

fn validateAndPrintSaxSource(allocator: Allocator, source: []const u8, stderr: anytype) !bool {
    var sax_parser = parser.SaxParser.init(allocator, source);
    var program = sax_parser.parse() catch |err| {
        switch (err) {
            parser.ParseError.UnknownTag => {
                const info: SaxValidationTrap = .{
                    .component_name = "SAX",
                    .err = SaxValidationError.SaxUnknownTag,
                    .line = 1,
                    .text = "unknown tag",
                };
                try sax_build.printTrapReport(stderr, trapReport(info));
                return false;
            },
            parser.ParseError.UnknownEvent => {
                const info: SaxValidationTrap = .{
                    .component_name = "SAX",
                    .err = SaxValidationError.SaxUnknownEvent,
                    .line = 1,
                    .text = "unknown event",
                };
                try sax_build.printTrapReport(stderr, trapReport(info));
                return false;
            },
            else => {},
        }
        try stderr.print("error: SAX parse failed: {}\n", .{err});
        return false;
    };
    defer program.deinit();

    for (program.components) |component| {
        if (findValidationTrap(allocator, component)) |info| {
            try sax_build.printTrapReport(stderr, trapReport(info));
            return false;
        }
    }

    return true;
}

fn findEventHandler(component: parser.Component, handler_name: []const u8) bool {
    for (component.handlers) |handler| {
        if (std.mem.eql(u8, handler.name, handler_name)) return true;
    }
    return false;
}

fn hasNativeEscape(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len >= 2 and trimmed[0] == '$' and trimmed[trimmed.len - 1] == '$') return true;
    }
    return false;
}

fn findValidationTrap(allocator: Allocator, component: parser.Component) ?SaxValidationTrap {
    var released = std.StringHashMap(void).init(allocator);
    defer released.deinit();
    for (component.release_vars) |name| {
        released.put(name, {}) catch return null;
    }

    for (component.state_vars) |sv| {
        if (!released.contains(sv.name)) {
            return .{
                .component_name = component.name,
                .err = SaxValidationError.SaxStateLeak,
                .line = 1,
                .text = sv.name,
            };
        }
    }

    for (component.dom_nodes) |node| {
        for (node.attrs) |attr| {
            if (attr.is_event) {
                const handler_name = attr.event_handler orelse {
                    return .{
                        .component_name = component.name,
                        .err = SaxValidationError.SaxEventEscape,
                        .line = 1,
                        .text = attr.name,
                    };
                };
                if (!findEventHandler(component, handler_name)) {
                    return .{
                        .component_name = component.name,
                        .err = SaxValidationError.SaxEventEscape,
                        .line = 1,
                        .text = handler_name,
                    };
                }
            }
            switch (attr.value) {
                .literal => {},
                .interpolation => |expr| {
                    if (std.mem.indexOfAny(u8, expr.expr, "^!") != null) {
                        return .{
                            .component_name = component.name,
                            .err = SaxValidationError.SaxInvalidInterpolation,
                            .line = 1,
                            .text = expr.expr,
                        };
                    }
                },
            }
        }
        for (node.children) |child| {
            switch (child) {
                .text => |piece| switch (piece) {
                    .text => {},
                    .interpolation => |expr| {
                        if (std.mem.indexOfAny(u8, expr.expr, "^!") != null) {
                            return .{
                                .component_name = component.name,
                                .err = SaxValidationError.SaxInvalidInterpolation,
                                .line = 1,
                                .text = expr.expr,
                            };
                        }
                    },
                },
                .node_index => {},
            }
        }
    }

    for (component.orphan_lines) |line| {
        if (hasNativeEscape(line.text)) {
            return .{
                .component_name = component.name,
                .err = SaxValidationError.SaxInvalidNativeEscape,
                .line = line.line,
                .text = line.text,
            };
        }
        if (std.mem.containsAtLeast(u8, line.text, 1, "call @render()")) {
            return .{
                .component_name = component.name,
                .err = SaxValidationError.SaxRenderOutsideHandler,
                .line = line.line,
                .text = line.text,
            };
        }
        if (std.mem.containsAtLeast(u8, line.text, 1, "store state+")) {
            return .{
                .component_name = component.name,
                .err = SaxValidationError.SaxStateWriteFromOutside,
                .line = line.line,
                .text = line.text,
            };
        }
    }

    for (component.handlers) |handler| {
        if (handler.is_ffi_wrapper and hasNativeEscape(handler.body) == false) continue;
        if (!handler.is_ffi_wrapper and hasNativeEscape(handler.body)) {
            return .{
                .component_name = component.name,
                .err = SaxValidationError.SaxInvalidNativeEscape,
                .line = 1,
                .text = handler.body,
            };
        }
    }
    for (component.lifecycle_hooks) |hook| {
        if (hook.is_ffi_wrapper and hasNativeEscape(hook.body) == false) continue;
        if (!hook.is_ffi_wrapper and hasNativeEscape(hook.body)) {
            return .{
                .component_name = component.name,
                .err = SaxValidationError.SaxInvalidNativeEscape,
                .line = 1,
                .text = hook.body,
            };
        }
    }

    return null;
}

fn compileSaxSource(allocator: Allocator, sax_file: []const u8, source: []const u8, stderr: anytype) !SaxCompilation {
    const component_name = sourceStem(sax_file);

    var compiler = sax.SaxCompiler.init(allocator);
    const artifacts = compiler.compile(source, component_name) catch |err| {
        try stderr.print("error: SAX compilation failed: {}\n", .{err});
        return error.CompileFailed;
    };

    return .{ .component_name = component_name, .artifacts = .{
        .sa_code = artifacts.sa_code,
        .airlock_js = artifacts.airlock_js,
        .index_html = artifacts.index_html,
    } };
}

fn buildDevArtifacts(
    allocator: Allocator,
    project_root: []const u8,
    sax_file: []const u8,
    source: []const u8,
    dist_dir: []const u8,
    stderr: anytype,
) !bool {
    if (!try validateAndPrintSaxSource(allocator, source, stderr)) return false;

    const compiled = compileSaxSource(allocator, sax_file, source, stderr) catch |err| switch (err) {
        error.CompileFailed => return false,
        else => return err,
    };
    const component_name = compiled.component_name;
    const artifacts = compiled.artifacts;
    defer artifacts.sa_code.deinit();
    defer artifacts.airlock_js.deinit();
    defer artifacts.index_html.deinit();

    const generated_source_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sa", .{ project_root, component_name });
    defer allocator.free(generated_source_path);

    const sa_path = try std.fs.path.join(allocator, &.{ dist_dir, "app.sa" });
    defer allocator.free(sa_path);

    const airlock_path = try std.fs.path.join(allocator, &.{ dist_dir, "airlock.js" });
    defer allocator.free(airlock_path);

    const html_path = try std.fs.path.join(allocator, &.{ dist_dir, "index.html" });
    defer allocator.free(html_path);

    const wasm_path = try std.fs.path.join(allocator, &.{ dist_dir, "app.wasm" });
    defer allocator.free(wasm_path);

    const build_code = try sax_build.buildBrowserWasmFromSourceText(
        allocator,
        generated_source_path,
        artifacts.sa_code.items,
        wasm_path,
        false,
        .release_small,
        .{},
        stderr,
    );
    if (build_code != 0) return false;

    try writeAllFile(sa_path, artifacts.sa_code.items);
    try writeAllFile(airlock_path, artifacts.airlock_js.items);
    try writeAllFile(html_path, artifacts.index_html.items);
    return true;
}

fn writeResponse(stream: std.net.Stream, status: std.http.Status, content_type: []const u8, body: []const u8) !void {
    try stream.writer().print("HTTP/1.1 {d} {s}\r\ncontent-type: {s}\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{
        @intFromEnum(status),
        status.phrase().?,
        content_type,
        body.len,
    });
    try stream.writeAll(body);
}

fn readRequestTarget(stream: std.net.Stream, allocator: Allocator) !?[]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    var byte: [1]u8 = undefined;
    while (true) {
        const n = try stream.read(&byte);
        if (n == 0) return null;
        try buf.append(byte[0]);
        if (buf.items.len >= 4 and std.mem.endsWith(u8, buf.items, "\r\n\r\n")) break;
        if (buf.items.len > 8192) return error.StreamTooLong;
    }
    const request = buf.items;
    const first_line_end = std.mem.indexOfScalar(u8, request, '\n') orelse return null;
    const first_line = std.mem.trimRight(u8, request[0..first_line_end], "\r");
    const first_space = std.mem.indexOfScalar(u8, first_line, ' ') orelse return null;
    const rest = first_line[first_space + 1..];
    const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return try allocator.dupe(u8, rest[0..second_space]);
}

fn serveStaticFile(allocator: Allocator, root_dir: []const u8, target: []const u8) ![]u8 {
    const relative = if (std.mem.eql(u8, target, "/")) "index.html" else if (std.mem.startsWith(u8, target, "/")) target[1..] else target;
    const full_path = try std.fs.path.join(allocator, &.{ root_dir, relative });
    defer allocator.free(full_path);
    return try std.fs.cwd().readFileAlloc(allocator, full_path, 16 * 1024 * 1024);
}

fn devServerLoop(
    allocator: Allocator,
    project_root: []const u8,
    sax_file: []const u8,
    dist_dir: []const u8,
    port: u16,
    stdout: anytype,
    stderr: anytype,
    stop_flag: *std.atomic.Value(bool),
) !void {
    const address = try std.net.Address.resolveIp("127.0.0.1", port);
    var server = try address.listen(.{ .reuse_address = true, .force_nonblocking = true });
    defer server.deinit();
    try stdout.print("✓ SAX dev server listening on http://127.0.0.1:{d}\n", .{port});

    var last_mtime: ?i128 = null;
    while (!stop_flag.load(.seq_cst)) {
        const stat = std.fs.cwd().statFile(sax_file) catch |err| {
            try stderr.print("error: failed to stat {s}: {}\n", .{ sax_file, err });
            std.Thread.sleep(50 * std.time.ns_per_ms);
            continue;
        };
        if (last_mtime == null or stat.mtime != last_mtime.?) {
            last_mtime = stat.mtime;
            const source = readSource(allocator, sax_file, stderr) catch {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            };
            defer allocator.free(source);
            const rebuilt = buildDevArtifacts(allocator, project_root, sax_file, source, dist_dir, stderr) catch |err| blk: {
                try stderr.print("error: SAX dev rebuild failed: {}\n", .{err});
                break :blk false;
            };
            if (rebuilt) {
                try stdout.print("✓ SAX dev build refreshed\n", .{});
            }
        }

        const conn = server.accept() catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer conn.stream.close();

        const target = readRequestTarget(conn.stream, allocator) catch |err| switch (err) {
            error.StreamTooLong => {
                try writeResponse(conn.stream, .request_header_fields_too_large, "text/plain", "request too large");
                continue;
            },
            else => return err,
        };
        if (target == null) continue;
        defer allocator.free(target.?);

        const body = serveStaticFile(allocator, dist_dir, target.?) catch |err| switch (err) {
            error.FileNotFound => {
                try writeResponse(conn.stream, .not_found, "text/plain", "not found");
                continue;
            },
            else => return err,
        };
        defer allocator.free(body);

        const content_type = if (std.mem.endsWith(u8, target.?, ".js"))
            "application/javascript"
        else if (std.mem.endsWith(u8, target.?, ".wasm"))
            "application/wasm"
        else if (std.mem.endsWith(u8, target.?, ".sa"))
            "text/plain"
        else
            "text/html";
        try writeResponse(conn.stream, .ok, content_type, body);
    }
}

pub fn executeSaxBuild(
    allocator: Allocator,
    sax_file: []const u8,
    output_dir: ?[]const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const source = try readSource(allocator, sax_file, stderr);
    defer allocator.free(source);
    if (!try validateAndPrintSaxSource(allocator, source, stderr)) return 1;

    const compiled = compileSaxSource(allocator, sax_file, source, stderr) catch |err| switch (err) {
        error.CompileFailed => return 1,
        else => return err,
    };
    const component_name = compiled.component_name;
    const artifacts = compiled.artifacts;
    defer artifacts.sa_code.deinit();
    defer artifacts.airlock_js.deinit();
    defer artifacts.index_html.deinit();

    const out_dir = output_dir orelse "dist";
    const source_dir_abs = try sourceDirAbs(allocator, sax_file);
    defer allocator.free(source_dir_abs);

    const generated_source_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sa", .{ source_dir_abs, component_name });
    defer allocator.free(generated_source_path);

    const sa_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sa", .{ out_dir, component_name });
    defer allocator.free(sa_path);

    const wasm_path = try std.fmt.allocPrint(allocator, "{s}/app.wasm", .{out_dir});
    defer allocator.free(wasm_path);

    const build_code = try sax_build.buildBrowserWasmFromSourceText(
        allocator,
        generated_source_path,
        artifacts.sa_code.items,
        wasm_path,
        false,
        .release_small,
        .{},
        stderr,
    );
    if (build_code != 0) return build_code;

    try writeAllFile(sa_path, artifacts.sa_code.items);

    const airlock_path = try std.fmt.allocPrint(allocator, "{s}/airlock.js", .{out_dir});
    defer allocator.free(airlock_path);
    try writeAllFile(airlock_path, artifacts.airlock_js.items);

    const html_path = try std.fmt.allocPrint(allocator, "{s}/index.html", .{out_dir});
    defer allocator.free(html_path);
    try writeAllFile(html_path, artifacts.index_html.items);

    try stdout.print("✓ SAX build successful\n", .{});
    try stdout.print("  .sa: {s}\n", .{sa_path});
    try stdout.print("  app.wasm: {s}\n", .{wasm_path});
    try stdout.print("  airlock.js: {s}\n", .{airlock_path});
    try stdout.print("  index.html: {s}\n", .{html_path});
    return 0;
}

pub fn executeSaxCheck(
    allocator: Allocator,
    sax_file: []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const source = try readSource(allocator, sax_file, stderr);
    defer allocator.free(source);
    if (!try validateAndPrintSaxSource(allocator, source, stderr)) return 1;

    const compiled = compileSaxSource(allocator, sax_file, source, stderr) catch |err| switch (err) {
        error.CompileFailed => return 1,
        else => return err,
    };
    const component_name = compiled.component_name;
    const artifacts = compiled.artifacts;
    defer artifacts.sa_code.deinit();
    defer artifacts.airlock_js.deinit();
    defer artifacts.index_html.deinit();

    const source_dir_abs = try sourceDirAbs(allocator, sax_file);
    defer allocator.free(source_dir_abs);

    const check_source_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sa", .{ source_dir_abs, component_name });
    defer allocator.free(check_source_path);

    const verified = try sax_build.compileSourceText(allocator, check_source_path, artifacts.sa_code.items, .{});
    switch (verified) {
        .trap => |report| {
            try sax_build.printTrapReport(stderr, report);
            return 1;
        },
        .ok => |ok| {
            var owned = ok;
            defer owned.deinit(allocator);
            try stdout.print("✓ SAX check passed\n", .{});
            return 0;
        },
    }
}

pub fn executeSaxNew(
    allocator: Allocator,
    project_name: []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    _ = stderr;

    try std.fs.cwd().makePath(project_name);

    const sax_template =
        \\ <Component name="App">
        \\   <state>
        \\     count = 0
        \\   </state>
        \\   <div class="app">
        \\     <h1>Hello SAX</h1>
        \\     <p>Count: {count}</p>
        \\     <button onclick={^increment}>+1</button>
        \\   </div>
        \\   @increment:
        \\   L_ENTRY:
        \\     count = load state+App_count as i64
        \\     count = add count, 1
        \\     store state+App_count, count as i64
        \\     call @render()
        \\     ret
        \\   !count
        \\ </Component>
    ;

    const sax_path = try std.fmt.allocPrint(allocator, "{s}/app.sax", .{project_name});
    defer allocator.free(sax_path);
    {
        var file = try std.fs.cwd().createFile(sax_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(sax_template);
    }

    const readme_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{project_name});
    defer allocator.free(readme_path);
    {
        var file = try std.fs.cwd().createFile(readme_path, .{ .truncate = true });
        defer file.close();
        try file.writer().print(
            \\ # {s}
            \\ 
            \\ SAX 项目脚手架
            \\ 
            \\ ## 编译
            \\ 
            \\ ```bash
            \\ sa sax build app.sax
            \\ ```
            \\ 
            \\ 生成 `dist/app.wasm`、`dist/airlock.js`、`dist/index.html` 和 `dist/app.sa`。
            \\ 
            \\ ## 开发
            \\ 
            \\ ```bash
            \\ sa sax dev
            \\ ```
            \\ 
            \\ ## 验证
            \\ 
            \\ ```bash
            \\ sa sax check app.sax
            \\ ```
            , .{project_name},
        );
    }

    const package_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{project_name});
    defer allocator.free(package_path);
    {
        var file = try std.fs.cwd().createFile(package_path, .{ .truncate = true });
        defer file.close();
        try file.writer().print(
            \\{{
            \\  "name": "{s}",
            \\  "private": true,
            \\  "type": "module",
            \\  "scripts": {{
            \\    "dev": "sa sax dev app.sax",
            \\    "build": "sa sax build app.sax",
            \\    "check": "sa sax check app.sax"
            \\  }}
            \\}}
            , .{project_name},
        );
    }

    try stdout.print("✓ SAX project created: {s}\n", .{project_name});
    try stdout.print("  app.sax: {s}\n", .{sax_path});
    try stdout.print("  README.md: {s}\n", .{readme_path});
    try stdout.print("  package.json: {s}\n", .{package_path});
    return 0;
}

pub fn executeSaxDev(
    allocator: Allocator,
    sax_file: []const u8,
    port: u16,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const project_root = try sourceDirAbs(allocator, sax_file);
    defer allocator.free(project_root);

    const dist_dir = try std.fs.path.join(allocator, &.{ project_root, "dist" });
    defer allocator.free(dist_dir);
    try std.fs.cwd().makePath(dist_dir);

    var stop_flag = std.atomic.Value(bool).init(false);
    try devServerLoop(allocator, project_root, sax_file, dist_dir, port, stdout, stderr, &stop_flag);
    return 0;
}

test "sax check reports unknown tag as sax trap" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const sax_source =
        \\<Component name="App">
        \\  <foo></foo>
        \\</Component>
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = "app.sax", .data = sax_source });

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try executeSaxCheck(std.testing.allocator, "app.sax", stdout_buf.writer().any(), stderr_buf.writer().any());
    try std.testing.expectEqual(@as(u8, 1), code);
    const report = trapReport(.{
        .component_name = "SAX",
        .err = SaxValidationError.SaxUnknownTag,
        .line = 1,
        .text = "unknown tag",
    });
    try std.testing.expectEqual(trap.Trap.sax_unknown_tag, report.trap);
}

test "sax check reports unknown event as sax trap" {
    var original_cwd = try std.fs.cwd().openDir(".", .{});
    defer original_cwd.close();

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    const sax_source =
        \\<Component name="App">
        \\  <div onhover={^x}></div>
        \\  @x:
        \\  L_ENTRY:
        \\    ret
        \\  !
        \\</Component>
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = "app.sax", .data = sax_source });

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    const code = try executeSaxCheck(std.testing.allocator, "app.sax", stdout_buf.writer().any(), stderr_buf.writer().any());
    try std.testing.expectEqual(@as(u8, 1), code);
    const report = trapReport(.{
        .component_name = "SAX",
        .err = SaxValidationError.SaxUnknownEvent,
        .line = 1,
        .text = "unknown event",
    });
    try std.testing.expectEqual(trap.Trap.sax_unknown_event, report.trap);
}
