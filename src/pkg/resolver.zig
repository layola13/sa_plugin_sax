const std = @import("std");
const builtin = @import("builtin");
const build_options = if (builtin.is_test) struct {
    pub const repo_root: []const u8 = ".";
} else @import("build_options");

fn pathHasPrecompiledArtifact(name: []const u8) bool {
    const lower = std.ascii.lowerString;
    var buf: [256]u8 = undefined;
    const slice = if (name.len <= buf.len) lower(&buf, name) else name;
    const ext = std.fs.path.extension(slice);
    return std.mem.eql(u8, ext, ".so") or
        std.mem.eql(u8, ext, ".dll") or
        std.mem.eql(u8, ext, ".dylib") or
        std.mem.eql(u8, ext, ".a") or
        std.mem.eql(u8, ext, ".lib") or
        std.mem.eql(u8, ext, ".whl") or
        std.mem.eql(u8, ext, ".node");
}

fn isIgnoredTreeDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".codex") or
        std.mem.eql(u8, name, ".mimir") or
        std.mem.eql(u8, name, ".kiro") or
        std.mem.eql(u8, name, ".code_index") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "dist") or
        std.mem.eql(u8, name, "artifacts") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, "zig-cache");
}

fn isIgnoredTreePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, ".zig-cache/") or
        std.mem.startsWith(u8, path, ".code_index/") or
        std.mem.startsWith(u8, path, "dist/") or
        std.mem.startsWith(u8, path, "artifacts/") or
        std.mem.startsWith(u8, path, "zig-out/") or
        std.mem.startsWith(u8, path, "zig-cache/");
}

fn hashSourceBytes(source: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(source);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn hashDelimiter(writer: anytype) !void {
    try writer.writeByte(0);
}

fn normalizedPath(path: []const u8) []u8 {
    return std.mem.replaceOwned(u8, std.heap.page_allocator, path, std.fs.path.sep_str, "/") catch unreachable;
}

fn appendPathComponent(writer: anytype, path: []const u8) !void {
    for (path) |c| {
        try writer.writeByte(if (std.fs.path.isSep(c)) '/' else c);
    }
}

fn packageTreeHash(allocator: std.mem.Allocator, root_dir: []const u8) ResolveError![32]u8 {
    var entries = std.ArrayList([]u8).init(allocator);
    defer {
        for (entries.items) |entry| allocator.free(entry);
        entries.deinit();
    }

    var root = std.fs.cwd().openDir(root_dir, .{ .iterate = true }) catch return error.PackageNotResolved;
    defer root.close();

    var walker = try root.walk(allocator);
    defer walker.deinit();

    while (walker.next() catch return error.PackageNotResolved) |entry| {
        switch (entry.kind) {
            .directory => {
                if (isIgnoredTreeDir(entry.basename)) continue;
            },
            .file => {
                if (isIgnoredTreePath(entry.path)) continue;
                if (pathHasPrecompiledArtifact(entry.basename)) continue;
                const copied = try allocator.dupe(u8, entry.path);
                errdefer allocator.free(copied);
                try entries.append(copied);
            },
            .sym_link, .unknown, .block_device, .character_device, .named_pipe, .unix_domain_socket, .whiteout, .door, .event_port => continue,
        }
    }

    std.mem.sort([]u8, entries.items, {}, struct {
        fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (entries.items) |entry_path| {
        const full_path = try std.fs.path.join(allocator, &.{ root_dir, entry_path });
        defer allocator.free(full_path);
        const file_bytes = readFileAlloc(allocator, full_path, 16 * 1024 * 1024) catch return error.PackageNotResolved;
        defer allocator.free(file_bytes);

        var normalized = std.ArrayList(u8).init(allocator);
        defer normalized.deinit();
        for (entry_path) |c| {
            try normalized.append(if (std.fs.path.isSep(c)) '/' else c);
        }
        hasher.update(normalized.items);
        hasher.update(&[_]u8{0});
        hasher.update(file_bytes);
        hasher.update(&[_]u8{0});
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub const ResolveError = error{
    OutOfMemory,
    InvalidPath,
    InvalidImportPath,
    PackageNotResolved,
    AmbiguousPackageVersion,
    PrecompiledArtifactRejected,
};

pub const Dependency = struct {
    url: []const u8,
    ref: []const u8,
};

pub const ResolveOptions = struct {
    project_root: ?[]const u8 = null,
    home_dir: ?[]const u8 = null,
    offline: bool = false,
    entry_candidates: []const []const u8 = &.{ "index.sa", "main.sa" },
    std_root: ?[]const u8 = null,
    max_local_file_bytes: usize = 16 * 1024 * 1024,
};

pub const ResolvedImport = struct {
    entry_path: []u8,
    entry_path_owned: bool = true,
    root_dir: ?[]u8 = null,
    package_identity: ?[]u8 = null,
    source_sha256: ?[32]u8 = null,
    source: []const u8,
    owned_source: ?[]u8 = null,
    mapped: ?[]align(std.heap.page_size_min) u8 = null,
    is_global: bool = false,

    pub fn deinit(self: *ResolvedImport, allocator: std.mem.Allocator) void {
        if (self.mapped) |mapped| {
            std.posix.munmap(mapped);
        } else if (self.owned_source) |owned_source| {
            allocator.free(owned_source);
        }
        if (self.entry_path_owned) allocator.free(self.entry_path);
        if (self.root_dir) |root_dir| allocator.free(root_dir);
        if (self.package_identity) |package_identity| allocator.free(package_identity);
        self.* = undefined;
    }
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn validateImportPath(path: []const u8) ResolveError!void {
    const trimmed = trim(path);
    if (trimmed.len == 0) return error.InvalidImportPath;
    if (std.mem.indexOfScalar(u8, trimmed, '\x00') != null) return error.InvalidImportPath;
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null or std.mem.indexOfScalar(u8, trimmed, '\r') != null) return error.InvalidImportPath;
}

fn validateIdentity(identity: []const u8) ResolveError!void {
    const trimmed = trim(identity);
    if (trimmed.len == 0) return error.InvalidImportPath;
    if (std.mem.indexOfScalar(u8, trimmed, '\x00') != null) return error.InvalidImportPath;
    if (std.mem.indexOfScalar(u8, trimmed, '\n') != null or std.mem.indexOfScalar(u8, trimmed, '\r') != null) return error.InvalidImportPath;
    if (std.mem.startsWith(u8, trimmed, "/") or std.mem.startsWith(u8, trimmed, "./") or std.mem.startsWith(u8, trimmed, "../")) {
        return error.InvalidImportPath;
    }
    if (std.mem.containsAtLeast(u8, trimmed, 1, "../")) return error.InvalidImportPath;
}

fn validateRef(ref: []const u8) ResolveError!void {
    const trimmed = trim(ref);
    if (trimmed.len == 0) return error.InvalidImportPath;
    if (std.mem.indexOfAny(u8, trimmed, " \t\r\n\x00") != null) return error.InvalidImportPath;
}

fn isPackageIdentity(import_path: []const u8) bool {
    const trimmed = trim(import_path);
    if (trimmed.len == 0) return false;
    if (std.fs.path.isAbsolute(trimmed)) return false;
    if (std.mem.startsWith(u8, trimmed, "./") or std.mem.startsWith(u8, trimmed, "../")) return false;
    return !std.mem.endsWith(u8, trimmed, ".sa") and
        !std.mem.endsWith(u8, trimmed, ".sai") and
        !std.mem.endsWith(u8, trimmed, ".sal");
}

fn projectRootPath(allocator: std.mem.Allocator, options: ResolveOptions) ResolveError![]u8 {
    if (options.project_root) |project_root| {
        return allocator.dupe(u8, project_root);
    }
    return std.fs.cwd().realpathAlloc(allocator, ".") catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidPath,
    };
}

fn homeDirPath(allocator: std.mem.Allocator, options: ResolveOptions) ResolveError![]u8 {
    if (options.home_dir) |home_dir| {
        return allocator.dupe(u8, home_dir);
    }
    return std.process.getEnvVarOwned(allocator, "HOME") catch {
        return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return error.InvalidPath;
    };
}

fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ResolveError![]u8 {
    return try std.fs.path.join(allocator, parts);
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ResolveError![]u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch return error.PackageNotResolved;
    defer file.close();

    return file.readToEndAlloc(allocator, max_bytes) catch error.PackageNotResolved;
}

fn mapFileReadOnly(path: []const u8) ResolveError!struct { mapped: []align(std.heap.page_size_min) u8, source: []u8 } {
    var file = std.fs.cwd().openFile(path, .{}) catch return error.PackageNotResolved;
    defer file.close();

    const end_pos = file.getEndPos() catch return error.PackageNotResolved;
    const len = std.math.cast(usize, end_pos) orelse return error.PackageNotResolved;
    if (len == 0) return error.PackageNotResolved;

    const mapped = std.posix.mmap(
        null,
        len,
        std.posix.PROT.READ,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PackageNotResolved,
    };
    return .{ .mapped = mapped, .source = mapped };
}

fn computeResolvedSourceHash(
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    root_dir: ?[]const u8,
    source: []const u8,
) ResolveError![32]u8 {
    _ = entry_path;
    if (root_dir) |dir| {
        return packageTreeHash(allocator, dir) catch |err| switch (err) {
            error.PackageNotResolved => hashSourceBytes(source),
            else => return err,
        };
    }
    return hashSourceBytes(source);
}

fn resolveRelativeImport(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    import_path: []const u8,
    max_bytes: usize,
) ResolveError!?ResolvedImport {
    var current_path = import_path;
    while (true) {
        const candidate = if (std.fs.path.isAbsolute(current_path))
            try allocator.dupe(u8, current_path)
        else
            try pathJoin(allocator, &.{ base_dir, current_path });
        defer allocator.free(candidate);

        const canonical = std.fs.cwd().realpathAlloc(allocator, candidate) catch {
            if (std.mem.indexOfScalar(u8, current_path, '/')) |slash| {
                current_path = current_path[slash + 1 ..];
                continue;
            }
            return null;
        };
        errdefer allocator.free(canonical);

        const source = try readFileAlloc(allocator, canonical, max_bytes);
        const source_hash = try computeResolvedSourceHash(allocator, canonical, null, source);
        return .{
            .entry_path = canonical,
            .source = source,
            .owned_source = source,
            .source_sha256 = source_hash,
        };
    }
}

fn findRequireEntry(entries: []const Dependency, identity: []const u8) ResolveError!?Dependency {
    var matched: ?Dependency = null;
    for (entries) |entry| {
        if (!std.mem.eql(u8, entry.url, identity)) continue;
        if (matched != null) return error.AmbiguousPackageVersion;
        matched = entry;
    }
    return matched;
}

fn resolveFromPackageRoot(
    allocator: std.mem.Allocator,
    root_dir: []const u8,
    package_identity: ?[]const u8,
    entry_candidates: []const []const u8,
    global: bool,
    max_bytes: usize,
) ResolveError!?ResolvedImport {
    const canonical_root = std.fs.cwd().realpathAlloc(allocator, root_dir) catch return null;
    errdefer allocator.free(canonical_root);

    var root_dir_handle = std.fs.cwd().openDir(canonical_root, .{ .iterate = true }) catch return null;
    defer root_dir_handle.close();

    for (entry_candidates) |entry_name| {
        const candidate = try pathJoin(allocator, &.{ canonical_root, entry_name });
        defer allocator.free(candidate);

        const canonical_entry = std.fs.cwd().realpathAlloc(allocator, candidate) catch continue;
        errdefer allocator.free(canonical_entry);

        if (global) {
            const mapped = try mapFileReadOnly(canonical_entry);
            const source_hash = try computeResolvedSourceHash(allocator, canonical_entry, canonical_root, mapped.source);
            var resolved: ResolvedImport = .{
                .entry_path = canonical_entry,
                .root_dir = canonical_root,
                .source = mapped.source,
                .owned_source = null,
                .mapped = mapped.mapped,
                .is_global = true,
                .source_sha256 = source_hash,
            };
            if (package_identity) |identity| {
                resolved.package_identity = try allocator.dupe(u8, identity);
            }
            return resolved;
        }

        const source = try readFileAlloc(allocator, canonical_entry, max_bytes);
        const source_hash = try computeResolvedSourceHash(allocator, canonical_entry, canonical_root, source);
        var resolved: ResolvedImport = .{
            .entry_path = canonical_entry,
            .root_dir = canonical_root,
            .source = source,
            .owned_source = source,
            .source_sha256 = source_hash,
        };
        if (package_identity) |identity| {
            resolved.package_identity = try allocator.dupe(u8, identity);
        }
        return resolved;
    }

    return null;
}

fn localVendorRoot(allocator: std.mem.Allocator, project_root: []const u8, identity: []const u8) ResolveError![]u8 {
    return pathJoin(allocator, &.{ project_root, "sa_vendor", identity });
}

fn globalCacheRoot(allocator: std.mem.Allocator, home_dir: []const u8, identity: []const u8, ref: []const u8) ResolveError![]u8 {
    const leaf = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ identity, ref });
    errdefer allocator.free(leaf);
    const root = try pathJoin(allocator, &.{ home_dir, ".sa", "pkg", leaf });
    allocator.free(leaf);
    return root;
}

fn sourceRepoRoot(allocator: std.mem.Allocator) ResolveError![]u8 {
    const source_path = @src().file;
    var current: []const u8 = source_path;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        current = std.fs.path.dirname(current) orelse return error.InvalidPath;
    }
    return allocator.dupe(u8, current);
}

fn resolveRootedImport(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    import_rel: []const u8,
    max_bytes: usize,
) ResolveError!?ResolvedImport {
    const candidate = try std.fs.path.join(allocator, &.{ root_path, import_rel });
    defer allocator.free(candidate);

    const canonical_entry = std.fs.cwd().realpathAlloc(allocator, candidate) catch return null;
    errdefer allocator.free(canonical_entry);
    const canonical_root = std.fs.cwd().realpathAlloc(allocator, root_path) catch return null;
    errdefer allocator.free(canonical_root);

    const source = std.fs.cwd().readFileAlloc(allocator, canonical_entry, max_bytes) catch return null;
    errdefer allocator.free(source);

    const source_hash = try computeResolvedSourceHash(allocator, canonical_entry, canonical_root, source);

    var resolved: ResolvedImport = .{
        .entry_path = canonical_entry,
        .root_dir = canonical_root,
        .source = source,
        .owned_source = source,
        .source_sha256 = source_hash,
        .is_global = true,
    };

    if (isPackageIdentity(import_rel)) {
        resolved.package_identity = try allocator.dupe(u8, import_rel);
    }

    return resolved;
}

fn resolveStandardImport(
    allocator: std.mem.Allocator,
    import_path: []const u8,
    options: ResolveOptions,
) ResolveError!?ResolvedImport {
    if (!std.mem.startsWith(u8, import_path, "sa_std/") and !std.mem.eql(u8, import_path, "sa_std")) return null;

    const std_rel = if (std.mem.eql(u8, import_path, "sa_std")) "" else import_path["sa_std/".len..];

    if (options.std_root) |std_root| {
        if (resolveRootedImport(allocator, std_root, std_rel, options.max_local_file_bytes) catch null) |resolved| {
            return resolved;
        }
    }

    const repo_std_root = try std.fs.path.join(allocator, &.{ build_options.repo_root, "sa_std" });
    defer allocator.free(repo_std_root);
    if (resolveRootedImport(allocator, repo_std_root, std_rel, options.max_local_file_bytes) catch null) |resolved| {
        return resolved;
    }

    if (projectRootPath(allocator, options) catch null) |project_root| {
        defer allocator.free(project_root);
        if (resolveRootedImport(allocator, project_root, import_path, options.max_local_file_bytes) catch null) |resolved| {
            return resolved;
        }
    }

    return null;
}

pub fn resolveImport(
    allocator: std.mem.Allocator,
    dependencies: []const Dependency,
    base_dir: []const u8,
    import_path: []const u8,
    options: ResolveOptions,
) ResolveError!ResolvedImport {
    if (try resolveStandardImport(allocator, import_path, options)) |resolved| {
        return resolved;
    }
    try validateImportPath(import_path);

    if (try resolveRelativeImport(allocator, base_dir, import_path, options.max_local_file_bytes)) |resolved| {
        return resolved;
    }

    if (!isPackageIdentity(import_path)) return error.PackageNotResolved;

    const project_root = try projectRootPath(allocator, options);
    defer allocator.free(project_root);

    const local_root = try localVendorRoot(allocator, project_root, import_path);
    defer allocator.free(local_root);

    if (try resolveFromPackageRoot(allocator, local_root, import_path, options.entry_candidates, false, options.max_local_file_bytes)) |resolved| {
        return resolved;
    } else {
        // unreachable because it throws
    }

    if (options.offline) return error.PackageNotResolved;

    const require_entry = try findRequireEntry(dependencies, import_path) orelse return error.PackageNotResolved;
    try validateIdentity(require_entry.url);
    try validateRef(require_entry.ref);

    const home_dir = try homeDirPath(allocator, options);
    defer allocator.free(home_dir);

    const global_root = try globalCacheRoot(allocator, home_dir, require_entry.url, require_entry.ref);
    defer allocator.free(global_root);

    if (try resolveFromPackageRoot(allocator, global_root, import_path, options.entry_candidates, true, options.max_local_file_bytes)) |resolved| {
        return resolved;
    }

    return error.PackageNotResolved;
}

test "resolveImport prefers a relative source file" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("src");
    var source_file = try tmp.dir.createFile("src/module.sa", .{ .truncate = true });
    defer source_file.close();
    try source_file.writeAll("@main() -> i32:\n    return 0\n");

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const resolved = try resolveImport(
        std.testing.allocator,
        &.{},
        root,
        "src/module.sa",
        .{},
    );
    defer {
        var owned = resolved;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expect(std.mem.endsWith(u8, resolved.entry_path, "src/module.sa"));
    try std.testing.expectEqualStrings("@main() -> i32:\n    return 0\n", resolved.source);
    try std.testing.expect(resolved.root_dir == null);
}

test "resolveImport falls back to local vendor package roots" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath("sa_vendor/github.com/example/pkg");
    var index = try tmp.dir.createFile("sa_vendor/github.com/example/pkg/index.sa", .{ .truncate = true });
    defer index.close();
    try index.writeAll("@pkg() -> i32:\n    return 123\n");

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    const resolved = try resolveImport(
        std.testing.allocator,
        &.{},
        root,
        "github.com/example/pkg",
        .{ .project_root = root },
    );
    defer {
        var owned = resolved;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expect(resolved.root_dir != null);
    try std.testing.expect(std.mem.endsWith(u8, resolved.entry_path, "sa_vendor/github.com/example/pkg/index.sa"));
    try std.testing.expectEqualStrings("@pkg() -> i32:\n    return 123\n", resolved.source);
    try std.testing.expect(!resolved.is_global);
}

test "resolveImport maps global cache entries read-only" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.makePath(".sa/pkg/github.com/example/pkg@v1");
    var index = try tmp.dir.createFile(".sa/pkg/github.com/example/pkg@v1/index.sa", .{ .truncate = true });
    defer index.close();
    try index.writeAll("@global() -> i32:\n    return 7\n");

    const home = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(home);

    const dependency = Dependency{
        .url = "github.com/example/pkg",
        .ref = "v1",
    };

    const resolved = try resolveImport(
        std.testing.allocator,
        &.{dependency},
        home,
        "github.com/example/pkg",
        .{ .project_root = home, .home_dir = home },
    );
    defer {
        var owned = resolved;
        owned.deinit(std.testing.allocator);
    }

    try std.testing.expect(resolved.is_global);
    try std.testing.expect(resolved.mapped != null);
    try std.testing.expect(std.mem.endsWith(u8, resolved.entry_path, ".sa/pkg/github.com/example/pkg@v1/index.sa"));
    try std.testing.expectEqualStrings("@global() -> i32:\n    return 7\n", resolved.source);
}

test "resolveImport returns PackageNotResolved when cache misses" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);

    try std.testing.expectError(
        error.PackageNotResolved,
        resolveImport(
            std.testing.allocator,
            &.{},
            root,
            "github.com/example/missing",
            .{ .project_root = root, .offline = true },
        ),
    );
}
