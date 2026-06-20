const std = @import("std");

pub const ParseError = error{
    OutOfMemory,
    UnexpectedToken,
    UnexpectedEOF,
    InvalidComponentName,
    InvalidStateVar,
    InvalidDOMTag,
    InvalidEventName,
    InvalidHandler,
    DuplicateStateVar,
    DuplicateHandler,
    DuplicateRoute,
    InvalidInterpolation,
    UnknownTag,
    UnknownEvent,
    InvalidAttribute,
    InvalidRelease,
    InvalidComponentBody,
    InvalidRouter,
    InvalidPage,
    InvalidStateInit,
    InvalidStateType,
    InvalidNativeEscape,
};

pub const StateType = enum {
    i1,
    i32,
    i64,
    f64,
    ptr,
};

pub const StateVar = struct {
    name: []const u8,
    init_expr: []const u8,
    ty: StateType,
    alloc_size: ?usize = null,
};

pub const HandlerLanguage = enum {
    sa,
    sla,
};

pub const TextPiece = union(enum) {
    text: []const u8,
    interpolation: Expr,
};

pub const AttrValue = union(enum) {
    literal: []const u8,
    interpolation: Expr,
};

pub const Expr = struct {
    expr: []const u8,
    deps: []const []const u8,
};

pub const Attribute = struct {
    name: []const u8,
    value: AttrValue,
    is_event: bool = false,
    event_handler: ?[]const u8 = null,
};

pub const DomChild = union(enum) {
    text: TextPiece,
    node_index: usize,
};

pub const DomNode = struct {
    tag: []const u8,
    attrs: []Attribute,
    children: []DomChild,
    self_closing: bool,
    alias: []const u8,
    text_index: ?usize = null,
};

pub const Handler = struct {
    name: []const u8,
    body: []const u8,
    language: HandlerLanguage = .sa,
    is_ffi_wrapper: bool = false,
};

pub const RoutePage = struct {
    path: []const u8,
    component: []const u8,
};

pub const LifecycleHook = struct {
    name: []const u8,
    body: []const u8,
    is_ffi_wrapper: bool = false,
};

pub const BodyLine = struct {
    line: u32,
    text: []const u8,
};

pub const Component = struct {
    name: []const u8,
    state_vars: []StateVar,
    dom_nodes: []DomNode,
    root_nodes: []usize,
    handlers: []Handler,
    lifecycle_hooks: []LifecycleHook,
    route_pages: []RoutePage,
    release_vars: []const []const u8,
    orphan_lines: []BodyLine,
};

pub const SaxProgram = struct {
    arena: std.heap.ArenaAllocator,
    components: []Component,

    pub fn deinit(self: *SaxProgram) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const tag_whitelist = struct {
    const layout = [_][]const u8{ "div", "section", "article", "header", "footer", "main", "nav", "aside" };
    const text = [_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6", "p", "span", "label", "strong", "em" };
    const inter = [_][]const u8{ "button", "input", "textarea", "select", "option", "form" };
    const list = [_][]const u8{ "ul", "ol", "li" };
    const media = [_][]const u8{ "img", "video", "canvas" };
    const table = [_][]const u8{ "table", "thead", "tbody", "tr", "th", "td" };
    const reserved = [_][]const u8{ "Router", "Page", "Slot" };

    fn contains(list_: []const []const u8, name: []const u8) bool {
        for (list_) |item| {
            if (std.mem.eql(u8, item, name)) return true;
        }
        return false;
    }

    fn valid(name: []const u8) bool {
        return contains(layout[0..], name) or
            contains(text[0..], name) or
            contains(inter[0..], name) or
            contains(list[0..], name) or
            contains(media[0..], name) or
            contains(table[0..], name) or
            contains(reserved[0..], name);
    }
};

const event_whitelist = [_][]const u8{
    "onclick",
    "oninput",
    "onchange",
    "onsubmit",
    "onkeydown",
    "onkeyup",
    "onfocus",
    "onblur",
    "onmouseenter",
    "onmouseleave",
};

const attr_whitelist = [_][]const u8{
    "class",
    "style",
    "value",
    "placeholder",
    "disabled",
    "id",
    "width",
    "height",
    "renderer",
};

const AttributeParseOptions = struct {
    allow_route_attrs: bool = false,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isWhitespaceOnly(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

fn trimText(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn stripLeadingSpace(text: []const u8) []const u8 {
    return std.mem.trimLeft(u8, text, " \t");
}

fn splitLines(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, text, '\n');
}

fn isSupportedEvent(name: []const u8) bool {
    for (event_whitelist) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn isSupportedAttr(name: []const u8) bool {
    for (attr_whitelist) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn sanitizeName(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    for (text, 0..) |c, idx| {
        const valid = if (idx == 0) isIdentStart(c) else isIdentChar(c);
        try out.append(if (valid) c else '_');
    }
    if (out.items.len == 0) try out.appendSlice("node");
    if (!isIdentStart(out.items[0])) {
        try out.insert(0, 'n');
    }
    return try out.toOwnedSlice();
}

fn lowercaseName(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try allocator.dupe(u8, text);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

fn inferStateType(init_expr: []const u8) ParseError!struct { ty: StateType, alloc_size: ?usize } {
    const trimmed = trimText(init_expr);
    if (trimmed.len == 0) return ParseError.InvalidStateInit;

    if (std.mem.startsWith(u8, trimmed, "alloc ")) {
        const size_text = trimText(trimmed["alloc ".len..]);
        if (size_text.len == 0) return ParseError.InvalidStateInit;
        const size = std.fmt.parseInt(usize, size_text, 10) catch return ParseError.InvalidStateInit;
        return .{ .ty = .ptr, .alloc_size = size };
    }

    if (std.mem.indexOf(u8, trimmed, " as ")) |idx| {
        const ty_text = trimText(trimmed[idx + 4 ..]);
        const ty = if (std.mem.eql(u8, ty_text, "i1")) StateType.i1 else if (std.mem.eql(u8, ty_text, "i32")) StateType.i32 else if (std.mem.eql(u8, ty_text, "i64")) StateType.i64 else if (std.mem.eql(u8, ty_text, "f64")) StateType.f64 else if (std.mem.eql(u8, ty_text, "ptr")) StateType.ptr else return ParseError.InvalidStateType;
        return .{ .ty = ty, .alloc_size = null };
    }

    if (std.mem.indexOfScalar(u8, trimmed, '.')) |_| {
        return .{ .ty = .f64, .alloc_size = null };
    }

    if (std.mem.eql(u8, trimmed, "0")) {
        return .{ .ty = .i64, .alloc_size = null };
    }

    _ = std.fmt.parseInt(i64, trimmed, 10) catch return ParseError.InvalidStateInit;
    return .{ .ty = .i64, .alloc_size = null };
}

fn parseStateTypeName(type_name: []const u8) ParseError!StateType {
    if (std.mem.eql(u8, type_name, "i1") or std.mem.eql(u8, type_name, "bool")) return .i1;
    if (std.mem.eql(u8, type_name, "i32")) return .i32;
    if (std.mem.eql(u8, type_name, "i64") or std.mem.eql(u8, type_name, "int")) return .i64;
    if (std.mem.eql(u8, type_name, "f64") or std.mem.eql(u8, type_name, "float")) return .f64;
    if (std.mem.eql(u8, type_name, "ptr")) return .ptr;
    return ParseError.InvalidStateType;
}

fn explicitStateAllocSize(init_expr: []const u8, ty: StateType) ParseError!?usize {
    if (ty != .ptr) return null;
    const trimmed = trimText(init_expr);
    if (!std.mem.startsWith(u8, trimmed, "alloc ")) return null;
    const size_text = trimText(trimmed["alloc ".len..]);
    if (size_text.len == 0) return ParseError.InvalidStateInit;
    return std.fmt.parseInt(usize, size_text, 10) catch return ParseError.InvalidStateInit;
}

fn isSlaFunctionHeader(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "fn")) return false;
    if (line.len == 2) return false;
    return std.ascii.isWhitespace(line[2]);
}

fn parseTextPieces(allocator: std.mem.Allocator, raw_text: []const u8) ParseError![]TextPiece {
    const trimmed = trimText(raw_text);
    if (trimmed.len == 0) return &.{};

    var pieces = std.ArrayList(TextPiece).init(allocator);
    errdefer pieces.deinit();

    var cursor: usize = 0;
    while (cursor < trimmed.len) {
        const open = std.mem.indexOfScalarPos(u8, trimmed, cursor, '{') orelse {
            const tail = trimmed[cursor..];
            if (tail.len != 0) try pieces.append(.{ .text = try allocator.dupe(u8, tail) });
            break;
        };
        const head = trimmed[cursor..open];
        if (head.len != 0) try pieces.append(.{ .text = try allocator.dupe(u8, head) });
        const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, '}') orelse return ParseError.InvalidInterpolation;
        const expr = trimText(trimmed[open + 1 .. close]);
        if (expr.len == 0) return ParseError.InvalidInterpolation;
        try pieces.append(.{ .interpolation = try parseExpr(allocator, expr) });
        cursor = close + 1;
    }

    return try pieces.toOwnedSlice();
}

fn parseAttrValue(allocator: std.mem.Allocator, text: []const u8) ParseError!AttrValue {
    const trimmed = trimText(text);
    if (trimmed.len == 0) return ParseError.InvalidAttribute;
    if (trimmed[0] == '{' and trimmed[trimmed.len - 1] == '}') {
        const expr = trimText(trimmed[1 .. trimmed.len - 1]);
        if (expr.len == 0) return ParseError.InvalidInterpolation;
        return .{ .interpolation = try parseExpr(allocator, expr) };
    }
    return .{ .literal = try allocator.dupe(u8, trimmed) };
}

fn parseExpr(allocator: std.mem.Allocator, expr: []const u8) ParseError!Expr {
    const expr_copy = try allocator.dupe(u8, expr);
    var deps = std.ArrayList([]const u8).init(allocator);
    errdefer deps.deinit();

    var tokens = std.mem.tokenizeAny(u8, expr, " \t\r\n()+-*/,%<>!&|^:=.");
    while (tokens.next()) |token| {
        if (!isIdentStart(token[0])) continue;
        var seen = false;
        for (deps.items) |dep| {
            if (std.mem.eql(u8, dep, token)) {
                seen = true;
                break;
            }
        }
        if (!seen) try deps.append(try allocator.dupe(u8, token));
    }

    return .{
        .expr = expr_copy,
        .deps = try deps.toOwnedSlice(),
    };
}

fn hasNativeEscape(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = trimText(line);
        if (trimmed.len >= 2 and trimmed[0] == '$' and trimmed[trimmed.len - 1] == '$') return true;
    }
    return false;
}

const DomBuilder = struct {
    allocator: std.mem.Allocator,
    component_name: []const u8,
    nodes: std.ArrayList(DomNode),
    alias_counts: std.StringHashMap(usize),

    fn init(allocator: std.mem.Allocator, component_name: []const u8) DomBuilder {
        return .{
            .allocator = allocator,
            .component_name = component_name,
            .nodes = std.ArrayList(DomNode).init(allocator),
            .alias_counts = std.StringHashMap(usize).init(allocator),
        };
    }

    fn deinit(self: *DomBuilder) void {
        self.nodes.deinit();
        self.alias_counts.deinit();
    }

    fn makeAlias(self: *DomBuilder, base: []const u8) ![]const u8 {
        const key = try self.allocator.dupe(u8, base);
        errdefer self.allocator.free(key);
        const count = self.alias_counts.get(key) orelse 0;
        try self.alias_counts.put(key, count + 1);
        if (count == 0) return key;
        return try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ key, count });
    }

    fn takeNodes(self: *DomBuilder) ![]DomNode {
        return try self.nodes.toOwnedSlice();
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    line: u32 = 1,
    col: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn parse(self: *Parser) ParseError!SaxProgram {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var components = std.ArrayList(Component).init(a);
        errdefer components.deinit();

        var pos: usize = 0;
        while (true) {
            self.skipWhitespaceAndComments(&pos);
            if (pos >= self.source.len) break;
            const component = try self.parseComponent(a, &pos);
            try components.append(component);
        }

        return .{
            .arena = arena,
            .components = try components.toOwnedSlice(),
        };
    }

    fn parseComponent(self: *Parser, allocator: std.mem.Allocator, pos: *usize) ParseError!Component {
        try self.expectString(pos, "<Component");
        self.skipInlineSpace(pos);
        try self.expectString(pos, "name");
        self.skipInlineSpace(pos);
        try self.expectChar(pos, '=');
        self.skipInlineSpace(pos);
        const name = try self.parseQuotedIdent(allocator, pos);
        try self.expectChar(pos, '>');

        var state_vars = std.ArrayList(StateVar).init(allocator);
        defer state_vars.deinit();
        var state_names = std.StringHashMap(void).init(allocator);
        defer state_names.deinit();

        var dom_builder = DomBuilder.init(allocator, name);
        defer dom_builder.deinit();

        var handlers = std.ArrayList(Handler).init(allocator);
        defer handlers.deinit();
        var handler_names = std.StringHashMap(void).init(allocator);
        defer handler_names.deinit();

        var lifecycle_hooks = std.ArrayList(LifecycleHook).init(allocator);
        defer lifecycle_hooks.deinit();
        var lifecycle_names = std.StringHashMap(void).init(allocator);
        defer lifecycle_names.deinit();

        var route_pages = std.ArrayList(RoutePage).init(allocator);
        defer route_pages.deinit();

        var release_vars = std.ArrayList([]const u8).init(allocator);
        defer release_vars.deinit();

        var orphan_lines = std.ArrayList(BodyLine).init(allocator);
        defer orphan_lines.deinit();

        self.skipWhitespaceAndComments(pos);
        if (self.peekString(pos, "<state>")) {
            try self.parseStateBlock(allocator, pos, &state_vars, &state_names);
        }

        self.skipWhitespaceAndComments(pos);
        const dom_start = pos.*;
        while (pos.* < self.source.len) {
            self.skipWhitespaceAndComments(pos);
            if (pos.* >= self.source.len) break;
            if (self.peekString(pos, "</Component>")) break;
            const line = self.peekLine(pos);
            const trimmed = stripLeadingSpace(line);
            if (trimmed.len != 0 and (trimmed[0] == '@' or trimmed[0] == '!' or isSlaFunctionHeader(trimmed))) break;
            self.advanceLine(pos);
        }
        const dom_end = pos.*;
        const dom_text = self.source[dom_start..dom_end];
        try self.parseDomChunk(allocator, &dom_builder, &route_pages, dom_text);

        while (true) {
            self.skipWhitespaceAndComments(pos);
            if (pos.* >= self.source.len) break;
            if (self.peekString(pos, "</Component>")) break;
            const line = self.peekLine(pos);
            const trimmed = stripLeadingSpace(line);
            if (trimmed.len == 0) {
                self.advanceLine(pos);
                continue;
            }
            if (trimmed[0] == '@') {
                const handler = try self.parseHandler(allocator, pos);
                if (!handler.is_ffi_wrapper and hasNativeEscape(handler.body)) return ParseError.InvalidNativeEscape;
                if (std.mem.eql(u8, handler.name, "onMount") or
                    std.mem.eql(u8, handler.name, "onUnmount") or
                    std.mem.eql(u8, handler.name, "onUpdate"))
                {
                    if (lifecycle_names.contains(handler.name)) return ParseError.DuplicateHandler;
                    try lifecycle_names.put(try allocator.dupe(u8, handler.name), {});
                    try lifecycle_hooks.append(.{ .name = handler.name, .body = handler.body, .is_ffi_wrapper = handler.is_ffi_wrapper });
                } else {
                    if (handler_names.contains(handler.name)) return ParseError.DuplicateHandler;
                    try handler_names.put(try allocator.dupe(u8, handler.name), {});
                    try handlers.append(handler);
                }
                continue;
            }
            if (isSlaFunctionHeader(trimmed)) {
                const handler = try self.parseSlaHandler(allocator, pos);
                if (handler_names.contains(handler.name)) return ParseError.DuplicateHandler;
                try handler_names.put(try allocator.dupe(u8, handler.name), {});
                try handlers.append(handler);
                continue;
            }
            if (trimmed[0] == '!') {
                try self.parseReleaseLines(allocator, pos, &release_vars);
                continue;
            }

            if (hasNativeEscape(trimmed)) return ParseError.InvalidNativeEscape;

            try orphan_lines.append(.{
                .line = self.line,
                .text = try allocator.dupe(u8, line),
            });
            self.advanceLine(pos);
        }

        self.skipWhitespaceAndComments(pos);
        try self.expectString(pos, "</Component>");

        // Validate DOM and handler references.
        var node_aliases = std.StringHashMap(void).init(allocator);
        defer node_aliases.deinit();
        for (dom_builder.nodes.items) |node| {
            _ = try node_aliases.put(node.alias, {});
        }

        // releases must refer to declared state vars.
        for (release_vars.items) |release_name| {
            if (!state_names.contains(release_name)) return ParseError.InvalidRelease;
        }

        const root_nodes = try self.copyRootNodes(allocator, dom_builder.nodes.items);
        const dom_nodes = try dom_builder.nodes.toOwnedSlice();

        return .{
            .name = try allocator.dupe(u8, name),
            .state_vars = try state_vars.toOwnedSlice(),
            .dom_nodes = dom_nodes,
            .root_nodes = root_nodes,
            .handlers = try handlers.toOwnedSlice(),
            .lifecycle_hooks = try lifecycle_hooks.toOwnedSlice(),
            .route_pages = try route_pages.toOwnedSlice(),
            .release_vars = try release_vars.toOwnedSlice(),
            .orphan_lines = try orphan_lines.toOwnedSlice(),
        };
    }

    fn copyRootNodes(
        self: *Parser,
        allocator: std.mem.Allocator,
        nodes: []const DomNode,
    ) ParseError![]usize {
        _ = self;
        var roots = std.ArrayList(usize).init(allocator);
        defer roots.deinit();
        for (nodes, 0..) |_, idx| {
            var is_child = false;
            for (nodes) |candidate| {
                for (candidate.children) |child| {
                    switch (child) {
                        .node_index => |child_idx| {
                            if (child_idx == idx) is_child = true;
                        },
                        else => {},
                    }
                }
            }
            if (!is_child) try roots.append(idx);
        }
        return try roots.toOwnedSlice();
    }

    fn parseStateBlock(
        self: *Parser,
        allocator: std.mem.Allocator,
        pos: *usize,
        state_vars: *std.ArrayList(StateVar),
        state_names: *std.StringHashMap(void),
    ) ParseError!void {
        try self.expectString(pos, "<state>");
        while (true) {
            self.skipWhitespaceAndComments(pos);
            if (self.peekString(pos, "</state>")) {
                try self.expectString(pos, "</state>");
                break;
            }
            const line = trimText(self.peekLine(pos));
            if (line.len == 0) {
                self.advanceLine(pos);
                continue;
            }
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return ParseError.InvalidStateVar;
            const lhs = trimText(line[0..eq]);
            const expr = trimText(line[eq + 1 ..]);
            var name = lhs;
            var explicit_ty: ?StateType = null;
            if (std.mem.indexOfScalar(u8, lhs, ':')) |colon| {
                name = trimText(lhs[0..colon]);
                const type_name = trimText(lhs[colon + 1 ..]);
                if (type_name.len == 0) return ParseError.InvalidStateType;
                explicit_ty = try parseStateTypeName(type_name);
            }
            if (name.len == 0 or expr.len == 0) return ParseError.InvalidStateVar;
            if (!isIdentStart(name[0])) return ParseError.InvalidStateVar;
            for (name[1..]) |c| {
                if (!isIdentChar(c)) return ParseError.InvalidStateVar;
            }
            if (state_names.contains(name)) return ParseError.DuplicateStateVar;
            try state_names.put(name, {});
            const init_info = try inferStateType(expr);
            const state_ty = explicit_ty orelse init_info.ty;
            const alloc_size = if (explicit_ty) |ty| try explicitStateAllocSize(expr, ty) else init_info.alloc_size;
            try state_vars.append(.{
                .name = try allocator.dupe(u8, name),
                .init_expr = try allocator.dupe(u8, expr),
                .ty = state_ty,
                .alloc_size = alloc_size,
            });
            self.advanceLine(pos);
        }
    }

    fn parseDomChunk(self: *Parser, allocator: std.mem.Allocator, builder: *DomBuilder, route_pages: *std.ArrayList(RoutePage), chunk: []const u8) ParseError!void {
        var pos: usize = 0;
        while (pos < chunk.len) {
            self.skipChunkWhitespace(chunk, &pos);
            if (pos >= chunk.len) break;
            if (chunk[pos] != '<') {
                const text_start = pos;
                while (pos < chunk.len and chunk[pos] != '<') : (pos += 1) {}
                const pieces = try parseTextPieces(allocator, chunk[text_start..pos]);
                if (pieces.len != 0 and !isWhitespaceOnly(chunk[text_start..pos])) return ParseError.InvalidComponentBody;
                continue;
            }
            const node_index = try self.parseDomNode(allocator, builder, route_pages, chunk, &pos);
            _ = node_index;
        }
    }

    fn parseDomNode(self: *Parser, allocator: std.mem.Allocator, builder: *DomBuilder, route_pages: *std.ArrayList(RoutePage), chunk: []const u8, pos: *usize) ParseError!usize {
        try self.expectChunkChar(chunk, pos, '<');
        if (pos.* < chunk.len and chunk[pos.*] == '/') return ParseError.InvalidDOMTag;

        const tag = try self.parseChunkIdent(allocator, chunk, pos);
        if (!tag_whitelist.valid(tag)) return ParseError.UnknownTag;
        if (std.mem.eql(u8, tag, "Router")) {
            try self.parseRouterBlock(allocator, route_pages, chunk, pos);
            return builder.nodes.items.len;
        }
        if (std.mem.eql(u8, tag, "Page")) return ParseError.InvalidPage;
        const alias = if (std.mem.indexOfScalar(u8, tag, '-') != null) try sanitizeName(allocator, tag) else try builder.makeAlias(tag);

        var attrs = std.ArrayList(Attribute).init(allocator);
        defer attrs.deinit();

        while (true) {
            self.skipChunkInlineSpace(chunk, pos);
            if (pos.* >= chunk.len) return ParseError.UnexpectedEOF;
            if (chunk[pos.*] == '/') {
                pos.* += 1;
                try self.expectChunkChar(chunk, pos, '>');
                try builder.nodes.append(.{
                    .tag = try allocator.dupe(u8, tag),
                    .attrs = try attrs.toOwnedSlice(),
                    .children = try allocator.alloc(DomChild, 0),
                    .self_closing = true,
                    .alias = try allocator.dupe(u8, alias),
                });
                return builder.nodes.items.len - 1;
            }
            if (chunk[pos.*] == '>') {
                pos.* += 1;
                break;
            }

            const attr = try self.parseAttribute(allocator, chunk, pos, .{});
            try attrs.append(attr);
        }

        try builder.nodes.append(.{
            .tag = try allocator.dupe(u8, tag),
            .attrs = try attrs.toOwnedSlice(),
            .children = try allocator.alloc(DomChild, 0),
            .self_closing = false,
            .alias = try allocator.dupe(u8, alias),
        });
        const idx = builder.nodes.items.len - 1;

        var children = std.ArrayList(DomChild).init(allocator);
        defer children.deinit();

        while (pos.* < chunk.len) {
            self.skipChunkWhitespace(chunk, pos);
            if (pos.* >= chunk.len) break;
            if (chunk[pos.*] == '<' and pos.* + 1 < chunk.len and chunk[pos.* + 1] == '/') {
                pos.* += 2;
                const close_tag = try self.parseChunkIdent(allocator, chunk, pos);
                if (!std.mem.eql(u8, close_tag, tag)) return ParseError.InvalidDOMTag;
                self.skipChunkInlineSpace(chunk, pos);
                try self.expectChunkChar(chunk, pos, '>');
                break;
            }

            if (chunk[pos.*] == '<') {
                const child_idx = try self.parseDomNode(allocator, builder, route_pages, chunk, pos);
                try children.append(.{ .node_index = child_idx });
                continue;
            }

            const text_start = pos.*;
            while (pos.* < chunk.len and chunk[pos.*] != '<') : (pos.* += 1) {}
            const pieces = try parseTextPieces(allocator, chunk[text_start..pos.*]);
            for (pieces) |piece| {
                try children.append(.{ .text = piece });
            }
        }

        builder.nodes.items[idx].children = try children.toOwnedSlice();
        return idx;
    }

    fn parseRouterBlock(self: *Parser, allocator: std.mem.Allocator, route_pages: *std.ArrayList(RoutePage), chunk: []const u8, pos: *usize) ParseError!void {
        self.skipChunkInlineSpace(chunk, pos);
        if (pos.* < chunk.len and chunk[pos.*] == '/') return ParseError.InvalidRouter;
        if (pos.* >= chunk.len or chunk[pos.*] != '>') return ParseError.InvalidRouter;
        pos.* += 1;

        while (pos.* < chunk.len) {
            self.skipChunkWhitespace(chunk, pos);
            if (pos.* >= chunk.len) return ParseError.UnexpectedEOF;
            if (chunk[pos.*] == '<' and pos.* + 1 < chunk.len and chunk[pos.* + 1] == '/') {
                pos.* += 2;
                const close_tag = try self.parseChunkIdent(allocator, chunk, pos);
                if (!std.mem.eql(u8, close_tag, "Router")) return ParseError.InvalidRouter;
                self.skipChunkInlineSpace(chunk, pos);
                try self.expectChunkChar(chunk, pos, '>');
                return;
            }
            if (chunk[pos.*] != '<') return ParseError.InvalidRouter;
            try self.parsePageNode(allocator, route_pages, chunk, pos);
        }
        return ParseError.UnexpectedEOF;
    }

    fn parsePageNode(self: *Parser, allocator: std.mem.Allocator, route_pages: *std.ArrayList(RoutePage), chunk: []const u8, pos: *usize) ParseError!void {
        try self.expectChunkChar(chunk, pos, '<');
        const tag = try self.parseChunkIdent(allocator, chunk, pos);
        if (!std.mem.eql(u8, tag, "Page")) return ParseError.InvalidPage;

        var path: ?[]const u8 = null;
        var component: ?[]const u8 = null;

        while (true) {
            self.skipChunkInlineSpace(chunk, pos);
            if (pos.* >= chunk.len) return ParseError.UnexpectedEOF;
            if (chunk[pos.*] == '/') {
                pos.* += 1;
                try self.expectChunkChar(chunk, pos, '>');
                if (path == null or component == null) return ParseError.InvalidPage;
                try route_pages.append(.{ .path = try allocator.dupe(u8, path.?), .component = try allocator.dupe(u8, component.?) });
                return;
            }
            if (chunk[pos.*] == '>') return ParseError.InvalidPage;

            const attr = try self.parseAttribute(allocator, chunk, pos, .{ .allow_route_attrs = true });
            if (attr.is_event) return ParseError.InvalidPage;
            const value = switch (attr.value) {
                .literal => |lit| lit,
                .interpolation => return ParseError.InvalidPage,
            };
            if (std.mem.eql(u8, attr.name, "path")) {
                path = value;
            } else if (std.mem.eql(u8, attr.name, "component")) {
                component = value;
            } else {
                return ParseError.InvalidPage;
            }
        }
    }

    fn parseAttribute(
        self: *Parser,
        allocator: std.mem.Allocator,
        chunk: []const u8,
        pos: *usize,
        options: AttributeParseOptions,
    ) ParseError!Attribute {
        const name = try self.parseChunkIdent(allocator, chunk, pos);
        self.skipChunkInlineSpace(chunk, pos);
        try self.expectChunkChar(chunk, pos, '=');
        self.skipChunkInlineSpace(chunk, pos);

        if (pos.* >= chunk.len) return ParseError.UnexpectedEOF;
        if (chunk[pos.*] == '"') {
            pos.* += 1;
            const start = pos.*;
            while (pos.* < chunk.len and chunk[pos.*] != '"') : (pos.* += 1) {}
            if (pos.* >= chunk.len) return ParseError.UnexpectedEOF;
            const raw = chunk[start..pos.*];
            pos.* += 1;
            if (!options.allow_route_attrs and !isSupportedAttr(name)) return ParseError.InvalidAttribute;
            const value = try parseAttrValue(allocator, raw);
            return .{ .name = name, .value = value };
        }

        if (chunk[pos.*] == '{') {
            pos.* += 1;
            const start = pos.*;
            while (pos.* < chunk.len and chunk[pos.*] != '}') : (pos.* += 1) {}
            if (pos.* >= chunk.len) return ParseError.UnexpectedEOF;
            const raw = trimText(chunk[start..pos.*]);
            pos.* += 1;
            if (!isSupportedEvent(name)) return ParseError.UnknownEvent;
            if (!std.mem.startsWith(u8, raw, "^")) return ParseError.InvalidEventName;
            const handler = trimText(raw[1..]);
            if (handler.len == 0) return ParseError.InvalidEventName;
            if (!isIdentStart(handler[0])) return ParseError.InvalidEventName;
            for (handler[1..]) |c| {
                if (!isIdentChar(c)) return ParseError.InvalidEventName;
            }
            return .{
                .name = name,
                .value = .{ .literal = try allocator.dupe(u8, "") },
                .is_event = true,
                .event_handler = try allocator.dupe(u8, handler),
            };
        }

        return ParseError.InvalidAttribute;
    }

    fn parseHandler(self: *Parser, allocator: std.mem.Allocator, pos: *usize) ParseError!Handler {
        const header = trimText(self.peekLine(pos));
        if (header.len < 3 or header[0] != '@' or header[header.len - 1] != ':') return ParseError.InvalidHandler;
        var name = trimText(header[1 .. header.len - 1]);
        var is_ffi_wrapper = false;
        if (std.mem.startsWith(u8, name, "ffi_wrapper")) {
            if (name.len == "ffi_wrapper".len) return ParseError.InvalidHandler;
            const next = name["ffi_wrapper".len];
            if (std.ascii.isWhitespace(next)) {
                const after = trimText(name["ffi_wrapper".len..]);
                if (after.len == 0) return ParseError.InvalidHandler;
                name = after;
                is_ffi_wrapper = true;
            }
        }
        if (!isIdentStart(name[0])) return ParseError.InvalidHandler;
        for (name[1..]) |c| {
            if (!isIdentChar(c)) return ParseError.InvalidHandler;
        }

        self.advanceLine(pos);
        const body_start = pos.*;
        while (pos.* < self.source.len) {
            const line = trimText(self.peekLine(pos));
            if (line.len == 0) {
                self.advanceLine(pos);
                continue;
            }
            if ((line[0] == '@' and line[line.len - 1] == ':') or line[0] == '!' or isSlaFunctionHeader(line)) break;
            if (self.peekString(pos, "</Component>")) break;
            self.advanceLine(pos);
        }
        const body = self.source[body_start..pos.*];
        return .{
            .name = try allocator.dupe(u8, name),
            .body = try allocator.dupe(u8, body),
            .is_ffi_wrapper = is_ffi_wrapper,
        };
    }

    fn parseSlaHandler(self: *Parser, allocator: std.mem.Allocator, pos: *usize) ParseError!Handler {
        while (pos.* < self.source.len and (self.source[pos.*] == ' ' or self.source[pos.*] == '\t' or self.source[pos.*] == '\r')) : (pos.* += 1) {}
        const body_start = pos.*;
        try self.expectString(pos, "fn");
        if (pos.* >= self.source.len or !std.ascii.isWhitespace(self.source[pos.*])) return ParseError.InvalidHandler;
        self.skipInlineSpace(pos);

        const name_start = pos.*;
        if (pos.* >= self.source.len or !isIdentStart(self.source[pos.*])) return ParseError.InvalidHandler;
        pos.* += 1;
        while (pos.* < self.source.len and isIdentChar(self.source[pos.*])) : (pos.* += 1) {}
        const name = self.source[name_start..pos.*];

        var cursor = pos.*;
        while (cursor < self.source.len and self.source[cursor] != '{') : (cursor += 1) {
            if (self.source[cursor] == '\n') return ParseError.InvalidHandler;
        }
        if (cursor >= self.source.len or self.source[cursor] != '{') return ParseError.InvalidHandler;

        var depth: usize = 0;
        var in_string = false;
        var escaped = false;
        while (cursor < self.source.len) : (cursor += 1) {
            const ch = self.source[cursor];
            if (in_string) {
                if (escaped) {
                    escaped = false;
                } else if (ch == '\\') {
                    escaped = true;
                } else if (ch == '"') {
                    in_string = false;
                }
                continue;
            }
            if (ch == '/' and cursor + 1 < self.source.len and self.source[cursor + 1] == '/') {
                while (cursor < self.source.len and self.source[cursor] != '\n') : (cursor += 1) {}
                if (cursor >= self.source.len) break;
            }
            if (ch == '"') {
                in_string = true;
                continue;
            }
            if (ch == '{') {
                depth += 1;
                continue;
            }
            if (ch == '}') {
                if (depth == 0) return ParseError.InvalidHandler;
                depth -= 1;
                if (depth == 0) {
                    cursor += 1;
                    break;
                }
            }
        }
        if (depth != 0) return ParseError.UnexpectedEOF;

        const body = self.source[body_start..cursor];
        while (pos.* < cursor) : (pos.* += 1) {
            if (self.source[pos.*] == '\n') {
                self.line += 1;
                self.col = 1;
            }
        }
        self.skipWhitespaceAndComments(pos);

        return .{
            .name = try allocator.dupe(u8, name),
            .body = try allocator.dupe(u8, body),
            .language = .sla,
        };
    }

    fn parseReleaseLines(self: *Parser, allocator: std.mem.Allocator, pos: *usize, out: *std.ArrayList([]const u8)) ParseError!void {
        while (pos.* < self.source.len) {
            const line = trimText(self.peekLine(pos));
            if (line.len == 0) {
                self.advanceLine(pos);
                continue;
            }
            if (line[0] != '!') break;
            var cursor: usize = 0;
            while (cursor < line.len) {
                while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {}
                if (cursor >= line.len) break;
                if (line[cursor] != '!') return ParseError.InvalidRelease;
                cursor += 1;
                const start = cursor;
                while (cursor < line.len and isIdentChar(line[cursor])) : (cursor += 1) {}
                const name = line[start..cursor];
                if (name.len == 0) return ParseError.InvalidRelease;
                try out.append(try allocator.dupe(u8, name));
            }
            self.advanceLine(pos);
            if (self.peekString(pos, "</Component>")) break;
        }
    }

    fn peekLine(self: *Parser, pos: *const usize) []const u8 {
        var end = pos.*;
        while (end < self.source.len and self.source[end] != '\n') : (end += 1) {}
        return self.source[pos.*..end];
    }

    fn advanceLine(self: *Parser, pos: *usize) void {
        while (pos.* < self.source.len and self.source[pos.*] != '\n') : (pos.* += 1) {}
        if (pos.* < self.source.len and self.source[pos.*] == '\n') {
            pos.* += 1;
            self.line += 1;
            self.col = 1;
        }
        self.skipWhitespaceAndComments(pos);
    }

    fn skipWhitespaceAndComments(self: *Parser, pos: *usize) void {
        while (pos.* < self.source.len) {
            const ch = self.source[pos.*];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                if (ch == '\n') {
                    self.line += 1;
                    self.col = 1;
                }
                pos.* += 1;
                continue;
            }
            if (ch == '/' and pos.* + 1 < self.source.len and self.source[pos.* + 1] == '/') {
                while (pos.* < self.source.len and self.source[pos.*] != '\n') : (pos.* += 1) {}
                if (pos.* < self.source.len and self.source[pos.*] == '\n') {
                    pos.* += 1;
                    self.line += 1;
                    self.col = 1;
                }
                continue;
            }
            break;
        }
    }

    fn skipInlineSpace(self: *Parser, pos: *usize) void {
        while (pos.* < self.source.len and (self.source[pos.*] == ' ' or self.source[pos.*] == '\t')) : (pos.* += 1) {}
    }

    fn peekString(self: *Parser, pos: *const usize, expected: []const u8) bool {
        if (pos.* + expected.len > self.source.len) return false;
        return std.mem.eql(u8, self.source[pos.* .. pos.* + expected.len], expected);
    }

    fn expectString(self: *Parser, pos: *usize, expected: []const u8) ParseError!void {
        if (!self.peekString(pos, expected)) return ParseError.UnexpectedToken;
        pos.* += expected.len;
    }

    fn expectChar(self: *Parser, pos: *usize, expected: u8) ParseError!void {
        if (pos.* >= self.source.len or self.source[pos.*] != expected) return ParseError.UnexpectedToken;
        pos.* += 1;
    }

    fn parseQuotedIdent(self: *Parser, allocator: std.mem.Allocator, pos: *usize) ParseError![]const u8 {
        if (pos.* >= self.source.len or self.source[pos.*] != '"') return ParseError.UnexpectedToken;
        pos.* += 1;
        const start = pos.*;
        while (pos.* < self.source.len and self.source[pos.*] != '"') : (pos.* += 1) {}
        if (pos.* >= self.source.len) return ParseError.UnexpectedEOF;
        const ident = self.source[start..pos.*];
        pos.* += 1;
        if (ident.len == 0) return ParseError.InvalidComponentName;
        if (!isIdentStart(ident[0])) return ParseError.InvalidComponentName;
        for (ident[1..]) |c| {
            if (!isIdentChar(c)) return ParseError.InvalidComponentName;
        }
        return try allocator.dupe(u8, ident);
    }

    fn skipChunkWhitespace(self: *Parser, chunk: []const u8, pos: *usize) void {
        _ = self;
        while (pos.* < chunk.len) {
            const ch = chunk[pos.*];
            if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                pos.* += 1;
                continue;
            }
            break;
        }
    }

    fn skipChunkInlineSpace(self: *Parser, chunk: []const u8, pos: *usize) void {
        _ = self;
        while (pos.* < chunk.len and (chunk[pos.*] == ' ' or chunk[pos.*] == '\t' or chunk[pos.*] == '\r')) : (pos.* += 1) {}
    }

    fn expectChunkChar(self: *Parser, chunk: []const u8, pos: *usize, expected: u8) ParseError!void {
        _ = self;
        if (pos.* >= chunk.len or chunk[pos.*] != expected) return ParseError.UnexpectedToken;
        pos.* += 1;
    }

    fn parseChunkIdent(self: *Parser, allocator: std.mem.Allocator, chunk: []const u8, pos: *usize) ParseError![]const u8 {
        _ = self;
        if (pos.* >= chunk.len or !isIdentStart(chunk[pos.*])) return ParseError.UnexpectedToken;
        const start = pos.*;
        pos.* += 1;
        while (pos.* < chunk.len and isIdentChar(chunk[pos.*])) : (pos.* += 1) {}
        return try allocator.dupe(u8, chunk[start..pos.*]);
    }
};

pub const SaxParser = Parser;

test "parser accepts a simple component" {
    const source =
        \\<Component name="Counter">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\
        \\  <div class="counter">
        \\    <h1>{count}</h1>
        \\    <button onclick={^inc}>+1</button>
        \\  </div>
        \\
        \\  @inc:
        \\  L_ENTRY:
        \\    count = load state+Counter_count as i64
        \\    call @render()
        \\    ret
        \\
        \\  !count
        \\</Component>
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var program = try parser.parse();
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.components.len);
    try std.testing.expectEqualStrings("Counter", program.components[0].name);
    try std.testing.expectEqual(@as(usize, 1), program.components[0].state_vars.len);
    try std.testing.expectEqual(@as(usize, 1), program.components[0].handlers.len);
    try std.testing.expectEqual(@as(usize, 3), program.components[0].dom_nodes.len);
    try std.testing.expectEqual(@as(usize, 1), program.components[0].root_nodes.len);
    try std.testing.expectEqual(@as(usize, 0), program.components[0].root_nodes[0]);
}

test "parser accepts the counter example from the docs" {
    const source =
        \\<Component name="Counter">
        \\  <state>
        \\    count = 0
        \\    last = 0
        \\  </state>
        \\
        \\  <div class="counter">
        \\    <h1>{count}</h1>
        \\    <p>Last updated: {last} ms ago</p>
        \\    <button onclick={^inc}>+1</button>
        \\    <button onclick={^dec}>-1</button>
        \\    <button onclick={^reset}>Reset</button>
        \\  </div>
        \\
        \\  @inc:
        \\  L_ENTRY:
        \\    count = load state+Counter_count as i64
        \\    count = add count, 1
        \\    store state+Counter_count, count as i64
        \\    last = call @sax_get_time()
        \\    store state+Counter_last, last as i64
        \\    call @render()
        \\    ret
        \\
        \\  @dec:
        \\  L_ENTRY:
        \\    count = load state+Counter_count as i64
        \\    count = sub count, 1
        \\    store state+Counter_count, count as i64
        \\    last = call @sax_get_time()
        \\    store state+Counter_last, last as i64
        \\    call @render()
        \\    ret
        \\
        \\  @reset:
        \\  L_ENTRY:
        \\    store state+Counter_count, 0 as i64
        \\    last = call @sax_get_time()
        \\    store state+Counter_last, last as i64
        \\    call @render()
        \\    ret
        \\
        \\  !count !last
        \\</Component>
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var program = try parser.parse();
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.components.len);
    const component = program.components[0];
    try std.testing.expectEqualStrings("Counter", component.name);
    try std.testing.expectEqual(@as(usize, 2), component.state_vars.len);
    try std.testing.expectEqual(@as(usize, 3), component.handlers.len);
    try std.testing.expectEqual(@as(usize, 2), component.release_vars.len);
    try std.testing.expectEqual(@as(usize, 6), component.dom_nodes.len);
    try std.testing.expectEqual(@as(usize, 1), component.root_nodes.len);
    try std.testing.expectEqual(@as(usize, 0), component.root_nodes[0]);
}

test "parser accepts typed state and sla handlers" {
    const source =
        \\<Component name="Counter">
        \\  <state>
        \\    count: i64 = 0
        \\  </state>
        \\  <section class="counter"><h1>{count}</h1><button onclick={^inc}>+1</button></section>
        \\  fn inc() {
        \\    count = count + 1;
        \\    render();
        \\  }
        \\  !count
        \\</Component>
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var program = try parser.parse();
    defer program.deinit();

    const component = program.components[0];
    try std.testing.expectEqual(@as(usize, 1), component.state_vars.len);
    try std.testing.expectEqualStrings("count", component.state_vars[0].name);
    try std.testing.expectEqual(StateType.i64, component.state_vars[0].ty);
    try std.testing.expectEqual(@as(usize, 1), component.handlers.len);
    try std.testing.expectEqualStrings("inc", component.handlers[0].name);
    try std.testing.expectEqual(HandlerLanguage.sla, component.handlers[0].language);
    try std.testing.expect(std.mem.containsAtLeast(u8, component.handlers[0].body, 1, "count = count + 1"));
}

test "parser records interpolation dependencies" {
    const source =
        \\<Component name="Deps">
        \\  <state>
        \\    count = 0
        \\    label = 0
        \\  </state>
        \\  <div><p>{count + label}</p></div>
        \\</Component>
    ;

    var parser = Parser.init(std.testing.allocator, source);
    var program = try parser.parse();
    defer program.deinit();

    const node = program.components[0].dom_nodes[0];
    try std.testing.expectEqual(@as(usize, 1), node.children.len);
    const child_node_idx = node.children[0].node_index;
    const child_node = program.components[0].dom_nodes[child_node_idx];
    try std.testing.expectEqual(@as(usize, 1), child_node.children.len);
    const text_piece = child_node.children[0].text;
    switch (text_piece) {
        .text => return error.TestUnexpectedResult,
        .interpolation => |expr| {
            try std.testing.expectEqualStrings("count + label", expr.expr);
            try std.testing.expectEqual(@as(usize, 2), expr.deps.len);
            try std.testing.expectEqualStrings("count", expr.deps[0]);
            try std.testing.expectEqualStrings("label", expr.deps[1]);
        },
    }
}

test "parser preserves literal spacing around interpolation pieces" {
    const source =
        \\<Component name="Spacing">
        \\  <state>
        \\    score = 7
        \\    latency = 180
        \\  </state>
        \\  <section>
        \\    <p>Score: {score}</p>
        \\    <p>{latency} ms</p>
        \\  </section>
        \\</Component>
    ;

    var parser = Parser.init(std.testing.allocator, source);
    var program = try parser.parse();
    defer program.deinit();

    const component = program.components[0];
    try std.testing.expectEqual(@as(usize, 3), component.dom_nodes.len);

    const score_p = component.dom_nodes[1];
    try std.testing.expectEqual(@as(usize, 2), score_p.children.len);
    switch (score_p.children[0].text) {
        .text => |text| try std.testing.expectEqualStrings("Score: ", text),
        .interpolation => return error.TestUnexpectedResult,
    }
    switch (score_p.children[1].text) {
        .text => return error.TestUnexpectedResult,
        .interpolation => |expr| try std.testing.expectEqualStrings("score", expr.expr),
    }

    const latency_p = component.dom_nodes[2];
    try std.testing.expectEqual(@as(usize, 2), latency_p.children.len);
    switch (latency_p.children[0].text) {
        .text => return error.TestUnexpectedResult,
        .interpolation => |expr| try std.testing.expectEqualStrings("latency", expr.expr),
    }
    switch (latency_p.children[1].text) {
        .text => |text| try std.testing.expectEqualStrings(" ms", text),
        .interpolation => return error.TestUnexpectedResult,
    }
}

test "parser accepts whitelisted DOM attrs and route attrs" {
    const source =
        \\<Component name="HomePage">
        \\  <input class="field" style="width: 100%" value="{count}" placeholder="Count" disabled="disabled" />
        \\  <canvas id="wgpu-canvas" width="800" height="600" renderer="wgpu"></canvas>
        \\</Component>
        \\<Component name="App">
        \\  <Router>
        \\    <Page path="/" component="HomePage" />
        \\  </Router>
        \\</Component>
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var program = try parser.parse();
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 2), program.components.len);
    try std.testing.expectEqual(@as(usize, 5), program.components[0].dom_nodes[0].attrs.len);
    try std.testing.expectEqual(@as(usize, 4), program.components[0].dom_nodes[1].attrs.len);
    try std.testing.expectEqual(@as(usize, 1), program.components[1].route_pages.len);
    try std.testing.expectEqualStrings("/", program.components[1].route_pages[0].path);
    try std.testing.expectEqualStrings("HomePage", program.components[1].route_pages[0].component);
}

test "parser rejects DOM attrs outside the whitelist" {
    const source =
        \\<Component name="Unsafe">
        \\  <div href="javascript:alert(1)"></div>
        \\</Component>
    ;
    var parser = Parser.init(std.testing.allocator, source);
    try std.testing.expectError(ParseError.InvalidAttribute, parser.parse());
}

test "parser marks ffi wrapper handlers" {
    const source =
        \\<Component name="Bridge">
        \\  <div></div>
        \\  @ffi_wrapper call_dom:
        \\  L_ENTRY:
        \\    raw = *state
        \\    return raw
        \\</Component>
    ;
    var parser = Parser.init(std.testing.allocator, source);
    var program = try parser.parse();
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.components.len);
    try std.testing.expectEqual(@as(usize, 1), program.components[0].handlers.len);
    try std.testing.expect(program.components[0].handlers[0].is_ffi_wrapper);
}
