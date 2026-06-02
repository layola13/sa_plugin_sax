const std = @import("std");
const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;

pub const LowerError = error{
    OutOfMemory,
    UnknownNode,
    UnknownStateVar,
    UnknownHandler,
    InvalidInterpolation,
    InvalidTextExpression,
};

pub const LowerOptions = struct {
    emit_shared_decls: bool = true,
    emit_app_alias: bool = false,
};

const StringPool = struct {
    allocator: Allocator,
    items: std.ArrayList([]const u8),

    fn init(allocator: Allocator) StringPool {
        return .{
            .allocator = allocator,
            .items = std.ArrayList([]const u8).init(allocator),
        };
    }

    fn deinit(self: *StringPool) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit();
        self.* = undefined;
    }

    fn add(self: *StringPool, text: []const u8) !usize {
        try self.items.append(try self.allocator.dupe(u8, text));
        return self.items.items.len - 1;
    }
};

const StateSlot = struct {
    offset: usize,
    size: usize,
};

fn stateTypeName(ty: parser.StateType) []const u8 {
    return switch (ty) {
        .i1 => "i1",
        .i32 => "i32",
        .i64 => "i64",
        .f64 => "f64",
        .ptr => "ptr",
    };
}

fn stateInitValueExpr(init_expr: []const u8, ty: parser.StateType) []const u8 {
    const trimmed = std.mem.trim(u8, init_expr, " \t\r");
    if (std.mem.lastIndexOf(u8, trimmed, " as ")) |idx| {
        const suffix = std.mem.trim(u8, trimmed[idx + 4 ..], " \t\r");
        if (std.mem.eql(u8, suffix, stateTypeName(ty))) {
            return std.mem.trimRight(u8, trimmed[0..idx], " \t\r");
        }
    }
    return trimmed;
}

fn f64BitsLiteral(init_expr: []const u8, ty: parser.StateType) LowerError!i64 {
    const value_text = stateInitValueExpr(init_expr, ty);
    const value = std.fmt.parseFloat(f64, value_text) catch return LowerError.InvalidTextExpression;
    return @bitCast(value);
}

const NodeSlots = struct {
    tag_const: usize,
    handle_slot: usize,
    text_slot: ?usize,
};

const InterpolationValue = struct {
    name: []const u8,
    ty: parser.StateType,
};

const InterpolationExprLowerer = struct {
    owner: *SaxLowerer,
    out: *std.ArrayList(u8),
    expr: []const u8,
    prefix: []const u8,
    scratch_allocator: Allocator,
    pos: usize = 0,
    next_tmp: usize = 0,

    fn lower(self: *InterpolationExprLowerer) LowerError!InterpolationValue {
        self.skipSpace();
        if (self.pos >= self.expr.len) return LowerError.InvalidTextExpression;
        const value = try self.parseAddSub();
        self.skipSpace();
        if (self.pos != self.expr.len) return LowerError.InvalidTextExpression;
        return value;
    }

    fn parseAddSub(self: *InterpolationExprLowerer) LowerError!InterpolationValue {
        var left = try self.parseMulDiv();
        while (true) {
            self.skipSpace();
            if (self.consume('+')) {
                const right = try self.parseMulDiv();
                left = try self.emitBinary("add", left, right);
                continue;
            }
            if (self.consume('-')) {
                const right = try self.parseMulDiv();
                left = try self.emitBinary("sub", left, right);
                continue;
            }
            return left;
        }
    }

    fn parseMulDiv(self: *InterpolationExprLowerer) LowerError!InterpolationValue {
        var left = try self.parseUnary();
        while (true) {
            self.skipSpace();
            if (self.consume('*')) {
                const right = try self.parseUnary();
                left = try self.emitBinary("mul", left, right);
                continue;
            }
            if (self.consume('/')) {
                const right = try self.parseUnary();
                left = try self.emitBinary("sdiv", left, right);
                continue;
            }
            return left;
        }
    }

    fn parseUnary(self: *InterpolationExprLowerer) LowerError!InterpolationValue {
        self.skipSpace();
        if (self.consume('+')) return self.parseUnary();
        if (self.consume('-')) {
            const value = try self.parseUnary();
            return try self.emitBinary("sub", .{ .name = "0", .ty = .i64 }, value);
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *InterpolationExprLowerer) LowerError!InterpolationValue {
        self.skipSpace();
        if (self.pos >= self.expr.len) return LowerError.InvalidTextExpression;

        if (self.consume('(')) {
            const value = try self.parseAddSub();
            self.skipSpace();
            if (!self.consume(')')) return LowerError.InvalidTextExpression;
            return value;
        }

        const c = self.expr[self.pos];
        if (std.ascii.isDigit(c)) return self.parseNumberLiteral();
        if (isIdentStart(c)) return self.parseStateLoad();
        return LowerError.InvalidTextExpression;
    }

    fn parseNumberLiteral(self: *InterpolationExprLowerer) LowerError!InterpolationValue {
        const start = self.pos;
        while (self.pos < self.expr.len and std.ascii.isDigit(self.expr[self.pos])) : (self.pos += 1) {}
        if (self.pos == start) return LowerError.InvalidTextExpression;
        var is_float = false;
        if (self.pos < self.expr.len and self.expr[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            const frac_start = self.pos;
            while (self.pos < self.expr.len and std.ascii.isDigit(self.expr[self.pos])) : (self.pos += 1) {}
            if (self.pos == frac_start) return LowerError.InvalidTextExpression;
        }
        if (self.pos < self.expr.len and (self.expr[self.pos] == 'e' or self.expr[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.expr.len and (self.expr[self.pos] == '+' or self.expr[self.pos] == '-')) self.pos += 1;
            const exp_start = self.pos;
            while (self.pos < self.expr.len and std.ascii.isDigit(self.expr[self.pos])) : (self.pos += 1) {}
            if (self.pos == exp_start) return LowerError.InvalidTextExpression;
        }
        return .{
            .name = if (is_float) (try self.emitF64Literal(self.expr[start..self.pos])).name else self.expr[start..self.pos],
            .ty = if (is_float) .f64 else .i64,
        };
    }

    fn emitF64Literal(self: *InterpolationExprLowerer, literal: []const u8) LowerError!InterpolationValue {
        const value = std.fmt.parseFloat(f64, literal) catch return LowerError.InvalidTextExpression;
        const bits: i64 = @bitCast(value);
        const bits_name = try self.nextName("f64_bits");
        try self.out.writer().print("  {s} = {d}\n", .{ bits_name, bits });
        return .{ .name = bits_name, .ty = .f64 };
    }

    fn parseStateLoad(self: *InterpolationExprLowerer) LowerError!InterpolationValue {
        const start = self.pos;
        self.pos += 1;
        while (self.pos < self.expr.len and isIdentChar(self.expr[self.pos])) : (self.pos += 1) {}
        const name = self.expr[start..self.pos];
        const idx = self.owner.stateVarIndex(name) orelse return LowerError.UnknownStateVar;
        const state_ty = self.owner.component.state_vars[idx].ty;
        if (state_ty == .ptr) return LowerError.InvalidTextExpression;

        const dest = try self.nextName("load");
        const slot_name = try self.owner.stateSlotConstName(name);
        defer self.owner.allocator.free(slot_name);
        switch (state_ty) {
            .i64 => {
                try self.out.writer().print("  {s} = load state+{s} as i64\n", .{ dest, slot_name });
                return .{ .name = dest, .ty = state_ty };
            },
            .f64 => {
                try self.out.writer().print("  {s} = load state+{s} as i64\n", .{ dest, slot_name });
                return .{ .name = dest, .ty = state_ty };
            },
            .i32, .i1 => {
                try self.out.writer().print("  {s} = load state+{s} as {s}\n", .{ dest, slot_name, stateTypeName(state_ty) });
                const widened = try self.nextName("wide");
                const op = if (state_ty == .i1) "zext" else "sext";
                try self.out.writer().print("  {s} = {s} {s} as i64\n", .{ widened, op, dest });
                return .{ .name = widened, .ty = .i64 };
            },
            .ptr => unreachable,
        }
    }

    fn emitBinary(self: *InterpolationExprLowerer, op: []const u8, left: InterpolationValue, right: InterpolationValue) LowerError!InterpolationValue {
        if (left.ty != .i64 or right.ty != .i64) return LowerError.InvalidTextExpression;
        const dest = try self.nextName("op");
        try self.out.writer().print("  {s} = {s} {s}, {s}\n", .{ dest, op, left.name, right.name });
        return .{ .name = dest, .ty = .i64 };
    }

    fn nextName(self: *InterpolationExprLowerer, kind: []const u8) LowerError![]const u8 {
        const name = try std.fmt.allocPrint(self.scratch_allocator, "{s}_{s}_{d}", .{ self.prefix, kind, self.next_tmp });
        self.next_tmp += 1;
        return name;
    }

    fn skipSpace(self: *InterpolationExprLowerer) void {
        while (self.pos < self.expr.len and std.ascii.isWhitespace(self.expr[self.pos])) : (self.pos += 1) {}
    }

    fn consume(self: *InterpolationExprLowerer, expected: u8) bool {
        if (self.pos >= self.expr.len or self.expr[self.pos] != expected) return false;
        self.pos += 1;
        return true;
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_';
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }
};

fn domEventName(attr_name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, attr_name, "on") and attr_name.len > 2) {
        return attr_name[2..];
    }
    return attr_name;
}

pub const SaxLowerer = struct {
    allocator: Allocator,
    component: parser.Component,
    state_slots: []StateSlot,
    state_size: usize,
    node_slots: []NodeSlots,
    string_pool: StringPool,
    event_handlers: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator, component: parser.Component) !SaxLowerer {
        var pool = StringPool.init(allocator);
        errdefer pool.deinit();

        const state_slots = try allocator.alloc(StateSlot, component.state_vars.len);
        errdefer allocator.free(state_slots);
        var state_size: usize = 0;
        for (component.state_vars, 0..) |sv, idx| {
            const size = stateVarSize(sv.ty);
            state_slots[idx] = .{ .offset = state_size, .size = size };
            state_size += size;
        }

        const node_slots = try allocator.alloc(NodeSlots, component.dom_nodes.len);
        errdefer allocator.free(node_slots);
        for (component.dom_nodes, 0..) |node, idx| {
            const tag_const = try pool.add(node.tag);
            node_slots[idx] = .{
                .tag_const = tag_const,
                .handle_slot = idx,
                .text_slot = null,
            };
        }

        var event_handlers = std.StringHashMap([]const u8).init(allocator);
        errdefer event_handlers.deinit();
        for (component.handlers) |handler| {
            try event_handlers.put(handler.name, handler.body);
        }

        return .{
            .allocator = allocator,
            .component = component,
            .state_slots = state_slots,
            .state_size = state_size,
            .node_slots = node_slots,
            .string_pool = pool,
            .event_handlers = event_handlers,
        };
    }

    pub fn deinit(self: *SaxLowerer) void {
        self.event_handlers.deinit();
        self.string_pool.deinit();
        self.allocator.free(self.node_slots);
        self.allocator.free(self.state_slots);
        self.* = undefined;
    }

    fn stateVarIndex(self: *const SaxLowerer, name: []const u8) ?usize {
        for (self.component.state_vars, 0..) |sv, idx| {
            if (std.mem.eql(u8, sv.name, name)) return idx;
        }
        return null;
    }

    fn stateSlot(self: *const SaxLowerer, name: []const u8) !StateSlot {
        const idx = self.stateVarIndex(name) orelse return LowerError.UnknownStateVar;
        return self.state_slots[idx];
    }

    fn nodeIndex(self: *const SaxLowerer, alias: []const u8) ?usize {
        for (self.component.dom_nodes, 0..) |node, idx| {
            if (std.mem.eql(u8, node.alias, alias)) return idx;
        }
        return null;
    }

    fn escapeText(allocator: Allocator, text: []const u8) ![]const u8 {
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        for (text) |c| {
            switch (c) {
                '\\' => try out.appendSlice("\\\\"),
                '"' => try out.appendSlice("\\\""),
                '\n' => try out.appendSlice("\\n"),
                '\r' => try out.appendSlice("\\r"),
                '\t' => try out.appendSlice("\\t"),
                else => try out.append(c),
            }
        }
        return try out.toOwnedSlice();
    }

    fn lowercaseName(allocator: Allocator, text: []const u8) ![]const u8 {
        const out = try allocator.dupe(u8, text);
        for (out) |*c| c.* = std.ascii.toLower(c.*);
        return out;
    }

    fn stringConstName(self: *const SaxLowerer, kind: []const u8, index: usize) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_{s}_{d}", .{ self.component.name, kind, index });
    }

    fn routeConstName(self: *const SaxLowerer, index: usize, kind: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_route_{s}_{d}", .{ self.component.name, kind, index });
    }

    fn stateVarSize(ty: parser.StateType) usize {
        return switch (ty) {
            .i1, .i32, .i64, .f64, .ptr => 8,
        };
    }

    fn componentStem(self: *const SaxLowerer) ![]const u8 {
        return try lowercaseName(self.allocator, self.component.name);
    }

    fn stateSlotConstName(self: *const SaxLowerer, state_name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ self.component.name, state_name });
    }

    fn stateSizeConstName(self: *const SaxLowerer) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_SIZE", .{self.component.name});
    }

    fn domSizeConstName(self: *const SaxLowerer) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_dom_SIZE", .{self.component.name});
    }

    fn ctxSizeConstName(self: *const SaxLowerer) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_CTX_SIZE", .{self.component.name});
    }

    fn ctxStateOffsetConstName(self: *const SaxLowerer) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_CTX_state", .{self.component.name});
    }

    fn ctxDomOffsetConstName(self: *const SaxLowerer) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_CTX_dom", .{self.component.name});
    }

    fn handlerExportName(self: *const SaxLowerer, handler_name: []const u8) ![]const u8 {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_{s}", .{ stem, handler_name });
    }

    fn handlerImplName(self: *const SaxLowerer, handler_name: []const u8) ![]const u8 {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_{s}_ffi", .{ stem, handler_name });
    }

    fn lifecycleImplName(self: *const SaxLowerer, hook_name: []const u8) ![]const u8 {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_{s}_ffi", .{ stem, hook_name });
    }

    fn initImplName(self: *const SaxLowerer) ![]const u8 {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_init_ffi", .{stem});
    }

    fn renderImplName(self: *const SaxLowerer) ![]const u8 {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_render_ffi", .{stem});
    }

    fn destroyImplName(self: *const SaxLowerer) ![]const u8 {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_destroy_ffi", .{stem});
    }

    fn routerInitImplName(self: *const SaxLowerer) ![]const u8 {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_router_init_ffi", .{stem});
    }

    fn hostSelectorConstName(self: *const SaxLowerer) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_host_app", .{self.component.name});
    }

    fn stateSlotExpr(self: *const SaxLowerer, name: []const u8) ![]const u8 {
        return try self.stateSlotConstName(name);
    }

    fn stateAllocSize(self: *const SaxLowerer) usize {
        return @max(self.state_size, 8);
    }

    fn domAllocSize(self: *const SaxLowerer) usize {
        const bytes = self.node_slots.len * 8;
        return @max(bytes, 8);
    }

    fn nodeTextBufferSize(self: *const SaxLowerer, node: parser.DomNode) usize {
        _ = self;
        var size: usize = 1;
        for (node.children) |child| {
            switch (child) {
                .text => |piece| switch (piece) {
                    .text => |txt| size += txt.len,
                    .interpolation => size += 64,
                },
                else => {},
            }
        }
        return size;
    }

    fn stateValueExpr(self: *const SaxLowerer, var_name: []const u8) ![]const u8 {
        const slot = try self.stateSlot(var_name);
        return try std.fmt.allocPrint(self.allocator, "state+{d}", .{slot.offset});
    }

    fn appendConstDecls(self: *const SaxLowerer, out: *std.ArrayList(u8)) !void {
        for (self.string_pool.items.items, 0..) |text, idx| {
            const escaped = try escapeText(self.allocator, text);
            defer self.allocator.free(escaped);
            try out.writer().print("@const sax_{s}_{d} = utf8:\"{s}\"\n", .{ self.component.name, idx, escaped });
        }
        if (self.string_pool.items.items.len != 0) try out.writer().writeByte('\n');

        for (self.component.route_pages, 0..) |page, idx| {
            const path_const = try self.routeConstName(idx, "path");
            defer self.allocator.free(path_const);
            const component_const = try self.routeConstName(idx, "component");
            defer self.allocator.free(component_const);
            const escaped_path = try escapeText(self.allocator, page.path);
            defer self.allocator.free(escaped_path);
            const escaped_component = try escapeText(self.allocator, page.component);
            defer self.allocator.free(escaped_component);
            try out.writer().print("@const {s} = utf8:\"{s}\"\n", .{ path_const, escaped_path });
            try out.writer().print("@const {s} = utf8:\"{s}\"\n", .{ component_const, escaped_component });
        }
        if (self.component.route_pages.len != 0) try out.writer().writeByte('\n');

        const host_selector = try self.hostSelectorConstName();
        defer self.allocator.free(host_selector);
        try out.writer().print("@const {s} = utf8:\"#app\"\n", .{host_selector});
        try out.writer().writeByte('\n');
    }

    fn appendExternDecls(_: *const SaxLowerer, out: *std.ArrayList(u8)) !void {
        const decls = [_][]const u8{
            "@extern sax_dom_query(*sel_ptr: ptr, sel_len: i64) -> i64",
            "@extern sax_dom_query_all(*sel_ptr: ptr, sel_len: i64, *out_ptr: ptr, max_count: i64) -> i64",
            "@extern sax_dom_create(*tag_ptr: ptr, tag_len: i64) -> i64",
            "@extern sax_dom_append_child(parent_h: i64, child_h: i64) -> void",
            "@extern sax_dom_remove_child(parent_h: i64, child_h: i64) -> void",
            "@extern sax_dom_remove_self(node_h: i64) -> void",
            "@extern sax_dom_insert_before(parent_h: i64, new_h: i64, ref_h: i64) -> void",
            "@extern sax_dom_set_text(node_h: i64, *text_ptr: ptr, text_len: i64) -> void",
            "@extern sax_dom_get_text(node_h: i64, *buf_ptr: ptr, buf_len: i64) -> i64",
            "@extern sax_dom_set_attr(node_h: i64, *key_ptr: ptr, key_len: i64, *val_ptr: ptr, val_len: i64) -> void",
            "@extern sax_dom_remove_attr(node_h: i64, *key_ptr: ptr, key_len: i64) -> void",
            "@extern sax_dom_get_attr(node_h: i64, *key_ptr: ptr, key_len: i64, *buf_ptr: ptr, buf_len: i64) -> i64",
            "@extern sax_dom_add_class(node_h: i64, *cls_ptr: ptr, cls_len: i64) -> void",
            "@extern sax_dom_remove_class(node_h: i64, *cls_ptr: ptr, cls_len: i64) -> void",
            "@extern sax_dom_toggle_class(node_h: i64, *cls_ptr: ptr, cls_len: i64, force: i1) -> i1",
            "@extern sax_dom_get_value(node_h: i64, *buf_ptr: ptr, buf_len: i64) -> i64",
            "@extern sax_dom_set_value(node_h: i64, *val_ptr: ptr, val_len: i64) -> void",
            "@extern sax_dom_bind_event(node_h: i64, *evt_ptr: ptr, evt_len: i64, *handler_ptr: ptr, handler_len: i64, ctx: ptr) -> void",
            "@extern sax_dom_unbind_event(node_h: i64, *evt_ptr: ptr, evt_len: i64, *handler_ptr: ptr, handler_len: i64, ctx: ptr) -> void",
            "@extern sax_set_timeout(*handler_ptr: ptr, handler_len: i64, delay_ms: i64) -> i64",
            "@extern sax_set_interval(*handler_ptr: ptr, handler_len: i64, delay_ms: i64) -> i64",
            "@extern sax_clear_timeout(id: i64) -> void",
            "@extern sax_clear_interval(id: i64) -> void",
            "@extern sax_router_get_path(*buf_ptr: ptr, buf_len: i64) -> i64",
            "@extern sax_router_push(*path_ptr: ptr, path_len: i64) -> void",
            "@extern sax_router_replace(*path_ptr: ptr, path_len: i64) -> void",
            "@extern sax_router_init(*path_ptr: ptr, path_len: i64) -> void",
            "@extern sax_http_get(*url_ptr: ptr, url_len: i64) -> i64",
            "@extern sax_http_post(*url_ptr: ptr, url_len: i64, *body_ptr: ptr, body_len: i64) -> i64",
            "@extern sax_get_time() -> i64",
            "@extern sax_itoa(value: i64, *buf_ptr: ptr, buf_len: i64) -> i64",
            "@extern sax_ftoa_bits(value_bits: i64, decimals: i64, *buf_ptr: ptr, buf_len: i64) -> i64",
            "@extern sax_mem_copy(*dst_ptr: ptr, *src_ptr: ptr, len: i64) -> void",
        };
        for (decls) |decl| try out.writer().print("{s}\n", .{decl});
        try out.writer().writeByte('\n');
    }

    fn appendStdImports(_: *const SaxLowerer, out: *std.ArrayList(u8)) !void {
        try out.writer().writeAll("@import \"sa_std/vec.sa\"\n\n");
    }

    fn appendArrayAdapter(_: *const SaxLowerer, out: *std.ArrayList(u8)) !void {
        try out.writer().writeAll(
            \\// SAX array adapter built on top of sa_std/vec
            \\@export sax_array_push(^vec: ptr, &elem_ptr: ptr, elem_size: u64) -> ^ptr:
            \\L_ENTRY:
            \\    vec = call @sa_vec_push(^vec, elem_ptr, elem_size)
            \\    return vec
            \\
            \\@export sax_array_get(&vec: ptr, index: u64) -> u64:
            \\L_ENTRY:
            \\    len = load vec+Vec_len as u64
            \\    in_range = ult index, len
            \\    br in_range -> L_GET_HIT, L_GET_MISS
            \\L_GET_HIT:
            \\    vec_ptr = load vec+Vec_ptr as ptr
            \\    elem_off = mul index, 8
            \\    elem_ptr = ptr_add vec_ptr, elem_off
            \\    value = load elem_ptr+0 as u64
            \\    !elem_ptr
            \\    !elem_off
            \\    !vec_ptr
            \\    !len
            \\    !in_range
            \\    !vec
            \\    return value
            \\L_GET_MISS:
            \\    !len
            \\    !in_range
            \\    !vec
            \\    return 0
            \\
            \\@export sax_array_remove(&vec: ptr, index: u64) -> void:
            \\L_ENTRY:
            \\    len = load vec+Vec_len as u64
            \\    in_range = ult index, len
            \\    br in_range -> L_REMOVE, L_DONE
            \\L_REMOVE:
            \\    next_len = sub len, 1
            \\    store vec+Vec_len, next_len as u64
            \\    !next_len
            \\    !len
            \\    !in_range
            \\    !vec
            \\    return
            \\L_DONE:
            \\    !len
            \\    !in_range
            \\    !vec
            \\    return
            \\
            \\@export sax_array_len(&vec: ptr) -> u64:
            \\L_ENTRY:
            \\    len = load vec+Vec_len as u64
            \\    !vec
            \\    return len
            \\
            \\@export sax_array_free(^vec: ptr) -> void:
            \\L_ENTRY:
            \\    call @sa_vec_free(^vec)
            \\    return
            \\
        );
    }

    fn emitLoadState(self: *const SaxLowerer, out: *std.ArrayList(u8), dest: []const u8, name: []const u8) !void {
        const idx = self.stateVarIndex(name) orelse return LowerError.UnknownStateVar;
        const slot_name = try self.stateSlotConstName(name);
        defer self.allocator.free(slot_name);
        const load_ty = if (self.component.state_vars[idx].ty == .f64) "i64" else stateTypeName(self.component.state_vars[idx].ty);
        try out.writer().print("  {s} = load state+{s} as {s}\n", .{ dest, slot_name, load_ty });
    }

    fn emitInterpolationExpr(
        self: *SaxLowerer,
        out: *std.ArrayList(u8),
        expr: parser.Expr,
        prefix: []const u8,
        scratch_allocator: Allocator,
    ) !InterpolationValue {
        if (std.mem.indexOfAny(u8, expr.expr, "^!") != null) return LowerError.InvalidInterpolation;
        var emitter = InterpolationExprLowerer{
            .owner = self,
            .out = out,
            .expr = expr.expr,
            .prefix = prefix,
            .scratch_allocator = scratch_allocator,
        };
        return try emitter.lower();
    }

    fn emitFormatInterpolationValue(
        _: *SaxLowerer,
        out: *std.ArrayList(u8),
        value: InterpolationValue,
        tmp_buf_name: []const u8,
        tmp_len_name: []const u8,
    ) !void {
        switch (value.ty) {
            .i64 => try out.writer().print("  {s} = call @sax_itoa({s}, *{s}, 64)\n", .{ tmp_len_name, value.name, tmp_buf_name }),
            .f64 => try out.writer().print("  {s} = call @sax_ftoa_bits({s}, 6, *{s}, 64)\n", .{ tmp_len_name, value.name, tmp_buf_name }),
            .i1, .i32, .ptr => return LowerError.InvalidTextExpression,
        }
    }

    fn emitStoreState(self: *const SaxLowerer, out: *std.ArrayList(u8), name: []const u8, value: []const u8, ty: parser.StateType) !void {
        if (self.stateVarIndex(name) == null) return LowerError.UnknownStateVar;
        const slot_name = try self.stateSlotConstName(name);
        defer self.allocator.free(slot_name);
        try out.writer().print("  store state+{s}, {s} as {s}\n", .{ slot_name, value, stateTypeName(ty) });
    }

    fn emitStringSliceCopy(self: *const SaxLowerer, out: *std.ArrayList(u8), dst_ptr: []const u8, src_const_idx: usize) !void {
        const const_name = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, src_const_idx });
        defer self.allocator.free(const_name);
        try out.writer().print("  call @sax_mem_copy(*{s}, *{s}, {})\n", .{ dst_ptr, const_name, self.string_pool.items.items[src_const_idx].len });
    }

    fn emitTextValue(
        self: *const SaxLowerer,
        out: *std.ArrayList(u8),
        node_name: []const u8,
        value_expr: []const u8,
        is_attr: bool,
        attr_key_idx: ?usize,
    ) !void {
        const key = if (is_attr) try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, attr_key_idx.? }) else "";
        defer if (is_attr) self.allocator.free(key);

        const buf_name = try std.fmt.allocPrint(self.allocator, "tmp_buf_{s}", .{node_name});
        defer self.allocator.free(buf_name);
        try out.writer().print("  {s} = stack_alloc 64\n", .{buf_name});
        try out.writer().print("  tmp_len_{s} = call @sax_itoa({s}, *{s}, 64)\n", .{ node_name, value_expr, buf_name });
        if (is_attr) {
            try out.writer().print("  call @sax_dom_set_attr({s}, *{s}, {}, *{s}, tmp_len_{s})\n", .{ node_name, key, self.string_pool.items.items[attr_key_idx.?].len, buf_name, node_name });
        } else {
            try out.writer().print("  call @sax_dom_set_text({s}, *{s}, tmp_len_{s})\n", .{ node_name, buf_name, node_name });
        }
    }

    fn emitTextPieceBuffer(
        self: *SaxLowerer,
        out: *std.ArrayList(u8),
        node: parser.DomNode,
        node_var: []const u8,
    ) !void {
        var has_text = false;
        for (node.children) |child| {
            switch (child) {
                .text => |piece| switch (piece) {
                    .text, .interpolation => {
                        has_text = true;
                        break;
                    },
                },
                else => {},
            }
        }
        if (!has_text) return;

        const buf_size = @max(self.nodeTextBufferSize(node), 32);
        const buf_name = try std.fmt.allocPrint(self.allocator, "text_buf_{s}", .{node.alias});
        defer self.allocator.free(buf_name);
        const cursor_name = try std.fmt.allocPrint(self.allocator, "text_len_{s}", .{node.alias});
        defer self.allocator.free(cursor_name);

        try out.writer().print("  {s} = stack_alloc {}\n", .{ buf_name, buf_size });
        try out.writer().print("  {s} = 0\n", .{cursor_name});

        var piece_index: usize = 0;
        for (node.children) |child| {
            switch (child) {
                .text => |piece| switch (piece) {
                    .text => |txt| {
                        const text_idx = try self.string_pool.add(txt);
                        const text_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, text_idx });
                        defer self.allocator.free(text_const);
                        const dst_name = try std.fmt.allocPrint(self.allocator, "text_dst_{s}_{d}", .{ node.alias, piece_index });
                        defer self.allocator.free(dst_name);
                        try out.writer().print("  {s} = ptr_add {s}, {s}\n", .{ dst_name, buf_name, cursor_name });
                        try out.writer().print("  call @sax_mem_copy(*{s}, *{s}, {})\n", .{ dst_name, text_const, txt.len });
                        try out.writer().print("  {s} = add {s}, {}\n", .{ cursor_name, cursor_name, txt.len });
                    },
                    .interpolation => |expr| {
                        var expr_arena = std.heap.ArenaAllocator.init(self.allocator);
                        defer expr_arena.deinit();
                        const expr_prefix = try std.fmt.allocPrint(self.allocator, "text_expr_{s}_{d}", .{ node.alias, piece_index });
                        defer self.allocator.free(expr_prefix);
                        const value = try self.emitInterpolationExpr(out, expr, expr_prefix, expr_arena.allocator());
                        const tmp_buf_name = try std.fmt.allocPrint(self.allocator, "text_tmp_{s}_{d}", .{ node.alias, piece_index });
                        defer self.allocator.free(tmp_buf_name);
                        const tmp_len_name = try std.fmt.allocPrint(self.allocator, "text_tmp_len_{s}_{d}", .{ node.alias, piece_index });
                        defer self.allocator.free(tmp_len_name);
                        const dst_name = try std.fmt.allocPrint(self.allocator, "text_dst_{s}_{d}", .{ node.alias, piece_index });
                        defer self.allocator.free(dst_name);
                        try out.writer().print("  {s} = stack_alloc 64\n", .{tmp_buf_name});
                        try self.emitFormatInterpolationValue(out, value, tmp_buf_name, tmp_len_name);
                        try out.writer().print("  {s} = ptr_add {s}, {s}\n", .{ dst_name, buf_name, cursor_name });
                        try out.writer().print("  call @sax_mem_copy(*{s}, *{s}, {s})\n", .{ dst_name, tmp_buf_name, tmp_len_name });
                        try out.writer().print("  {s} = add {s}, {s}\n", .{ cursor_name, cursor_name, tmp_len_name });
                    },
                },
                else => {},
            }
            piece_index += 1;
        }

        try out.writer().print("  call @sax_dom_set_text({s}, *{s}, {s})\n", .{ node_var, buf_name, cursor_name });
    }

    fn emitNodeAttrs(
        self: *SaxLowerer,
        out: *std.ArrayList(u8),
        node: parser.DomNode,
        node_var: []const u8,
        ctx_var: []const u8,
        bind_events: bool,
    ) !void {
        for (node.attrs, 0..) |attr, idx| {
            if (attr.is_event) {
                if (!bind_events) continue;
                const handler_name = attr.event_handler orelse return LowerError.UnknownHandler;
                if (self.event_handlers.get(handler_name) == null) return LowerError.UnknownHandler;

                const event_name = domEventName(attr.name);
                const evt_idx = try self.string_pool.add(event_name);
                const evt_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, evt_idx });
                defer self.allocator.free(evt_const);
                const handler_export = try self.handlerExportName(handler_name);
                defer self.allocator.free(handler_export);
                const handler_idx = try self.string_pool.add(handler_export);
                const handler_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, handler_idx });
                defer self.allocator.free(handler_const);
                try out.writer().print("  call @sax_dom_bind_event({s}, *{s}, {}, *{s}, {}, {s})\n", .{ node_var, evt_const, event_name.len, handler_const, handler_export.len, ctx_var });
                continue;
            }

            switch (attr.value) {
                .literal => |lit| {
                    const key_idx = try self.string_pool.add(attr.name);
                    const val_idx = try self.string_pool.add(lit);
                    const key_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, key_idx });
                    defer self.allocator.free(key_const);
                    const val_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, val_idx });
                    defer self.allocator.free(val_const);
                    try out.writer().print("  call @sax_dom_set_attr({s}, *{s}, {}, *{s}, {})\n", .{ node_var, key_const, attr.name.len, val_const, lit.len });
                },
                .interpolation => |expr| {
                    try self.emitInterpolatedValue(out, node_var, attr.name, expr, true);
                },
            }
            _ = idx;
        }
    }

    fn emitNodeInit(self: *SaxLowerer, out: *std.ArrayList(u8), ctx_var: []const u8, idx: usize) !void {
        const node = self.component.dom_nodes[idx];
        const slot = self.node_slots[idx];
        const node_var = try std.fmt.allocPrint(self.allocator, "node_{d}", .{idx});
        defer self.allocator.free(node_var);

        const tag_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, slot.tag_const });
        defer self.allocator.free(tag_const);
        try out.writer().print("  {s} = call @sax_dom_create(*{s}, {})\n", .{ node_var, tag_const, self.string_pool.items.items[slot.tag_const].len });
        const node_slot = try self.nodeSlotConstName(node.alias);
        defer self.allocator.free(node_slot);
        try out.writer().print("  store dom+{s}, {s} as i64\n", .{ node_slot, node_var });

        try self.emitNodeAttrs(out, node, node_var, ctx_var, true);
    }

    fn emitNodeAttachChildren(self: *const SaxLowerer, out: *std.ArrayList(u8), idx: usize) !void {
        const node = self.component.dom_nodes[idx];
        if (node.self_closing) return;

        const node_var = try std.fmt.allocPrint(self.allocator, "node_{d}", .{idx});
        defer self.allocator.free(node_var);

        for (node.children) |child| {
            switch (child) {
                .node_index => |child_idx| {
                    const child_var = try std.fmt.allocPrint(self.allocator, "node_{d}", .{child_idx});
                    defer self.allocator.free(child_var);
                    try out.writer().print("  call @sax_dom_append_child({s}, {s})\n", .{ node_var, child_var });
                },
                else => {},
            }
        }
    }

    fn nodeSlotConstName(self: *const SaxLowerer, alias: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "sax_{s}_node_{s}", .{ self.component.name, alias });
    }

    fn emitNodeRender(self: *SaxLowerer, out: *std.ArrayList(u8), ctx_var: []const u8, idx: usize) !void {
        const node = self.component.dom_nodes[idx];
        const node_var = try std.fmt.allocPrint(self.allocator, "node_{d}", .{idx});
        defer self.allocator.free(node_var);

        const node_slot = try self.nodeSlotConstName(node.alias);
        defer self.allocator.free(node_slot);
        try out.writer().print("  {s} = load dom+{s} as ptr\n", .{ node_var, node_slot });
        try self.emitNodeAttrs(out, node, node_var, ctx_var, false);
        try self.emitTextPieceBuffer(out, node, node_var);
    }

    fn emitInterpolatedValue(self: *SaxLowerer, out: *std.ArrayList(u8), node_var: []const u8, key_name: []const u8, expr: parser.Expr, is_attr: bool) !void {
        var expr_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer expr_arena.deinit();
        const expr_prefix = try std.fmt.allocPrint(self.allocator, "attr_expr_{s}_{s}", .{ node_var, key_name });
        defer self.allocator.free(expr_prefix);
        const value = try self.emitInterpolationExpr(out, expr, expr_prefix, expr_arena.allocator());

        const buf_name = try std.fmt.allocPrint(self.allocator, "interp_buf_{s}", .{key_name});
        defer self.allocator.free(buf_name);
        const len_name = try std.fmt.allocPrint(self.allocator, "interp_len_{s}", .{key_name});
        defer self.allocator.free(len_name);
        try out.writer().print("  {s} = stack_alloc 64\n", .{buf_name});
        try self.emitFormatInterpolationValue(out, value, buf_name, len_name);
        if (is_attr) {
            const key_idx = try self.string_pool.add(key_name);
            const key_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, key_idx });
            defer self.allocator.free(key_const);
            try out.writer().print("  call @sax_dom_set_attr({s}, *{s}, {}, *{s}, {s})\n", .{
                node_var,
                key_const,
                key_name.len,
                buf_name,
                len_name,
            });
        } else {
            try out.writer().print("  call @sax_dom_set_text({s}, *{s}, {s})\n", .{
                node_var,
                buf_name,
                len_name,
            });
        }
    }

    fn emitHandler(self: *SaxLowerer, out: *std.ArrayList(u8), handler: parser.Handler) !void {
        const body = handler.body;
        const export_name = try self.handlerExportName(handler.name);
        defer self.allocator.free(export_name);
        const impl_name = try self.handlerImplName(handler.name);
        defer self.allocator.free(impl_name);
        const ctx_state_name = try self.ctxStateOffsetConstName();
        defer self.allocator.free(ctx_state_name);
        const ctx_dom_name = try self.ctxDomOffsetConstName();
        defer self.allocator.free(ctx_dom_name);
        try out.writer().print("@export {s}(ctx: ptr):\nL_ENTRY:\n  call @{s}(ctx)\n  return\n\n", .{ export_name, impl_name });
        try out.writer().print("@ffi_wrapper {s}(ctx: ptr):\n", .{impl_name});
        try out.writer().print("L_ENTRY:\n  state = load ctx+{s} as ptr\n  dom = load ctx+{s} as ptr\n", .{ ctx_state_name, ctx_dom_name });
        try self.emitHandlerBody(out, body);
        try out.writer().writeByte('\n');
    }

    fn emitHandlerBody(self: *SaxLowerer, out: *std.ArrayList(u8), body: []const u8) !void {
        var lines = std.mem.splitScalar(u8, body, '\n');
        var emitted_entry = false;
        while (lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            if (!emitted_entry and std.mem.eql(u8, trimmed, "L_ENTRY:")) {
                emitted_entry = true;
                continue;
            }
            if (std.mem.containsAtLeast(u8, trimmed, 1, "call @render()")) {
                try self.emitRenderAfterWrites(out, body, true);
                continue;
            }
            try out.writer().print("{s}\n", .{trimmed});
        }
    }

    fn emitLifecycleHook(self: *SaxLowerer, out: *std.ArrayList(u8), hook: parser.LifecycleHook) !void {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        const export_name = try std.fmt.allocPrint(self.allocator, "sax_{s}_{s}", .{ stem, hook.name });
        defer self.allocator.free(export_name);
        const impl_name = try self.lifecycleImplName(hook.name);
        defer self.allocator.free(impl_name);
        const ctx_state_name = try self.ctxStateOffsetConstName();
        defer self.allocator.free(ctx_state_name);
        const ctx_dom_name = try self.ctxDomOffsetConstName();
        defer self.allocator.free(ctx_dom_name);

        try out.writer().print("@export {s}(ctx: ptr):\nL_ENTRY:\n  call @{s}(ctx)\n  return\n\n", .{ export_name, impl_name });
        try out.writer().print("@ffi_wrapper {s}(ctx: ptr):\n", .{impl_name});
        try out.writer().print("L_ENTRY:\n  state = load ctx+{s} as ptr\n  dom = load ctx+{s} as ptr\n", .{ ctx_state_name, ctx_dom_name });
        var lines = std.mem.splitScalar(u8, hook.body, '\n');
        var emitted_entry = false;
        while (lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            if (!emitted_entry and std.mem.eql(u8, trimmed, "L_ENTRY:")) {
                emitted_entry = true;
                continue;
            }
            if (std.mem.containsAtLeast(u8, trimmed, 1, "call @render()")) {
                try self.emitRenderAfterWrites(out, hook.body, true);
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "id = call @sax_set_interval(^")) {
                const open = std.mem.indexOfScalar(u8, trimmed, '^') orelse return LowerError.UnknownHandler;
                const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, ',') orelse return LowerError.UnknownHandler;
                const handler_name = std.mem.trim(u8, trimmed[open + 1 .. close], " ");
                if (self.event_handlers.get(handler_name) == null) return LowerError.UnknownHandler;
                const handler_export = try self.handlerExportName(handler_name);
                defer self.allocator.free(handler_export);
                const handler_idx = try self.string_pool.add(handler_export);
                const handler_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, handler_idx });
                defer self.allocator.free(handler_const);
                const delay_start = std.mem.indexOf(u8, trimmed, ",") orelse return LowerError.UnknownHandler;
                const delay = std.mem.trim(u8, trimmed[delay_start + 1 .. trimmed.len - 1], " ");
                try out.writer().print("  id = call @sax_set_interval(*{s}, {}, {s})\n", .{ handler_const, handler_export.len, delay });
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "id = call @sax_set_timeout(^")) {
                const open = std.mem.indexOfScalar(u8, trimmed, '^') orelse return LowerError.UnknownHandler;
                const close = std.mem.indexOfScalarPos(u8, trimmed, open + 1, ',') orelse return LowerError.UnknownHandler;
                const handler_name = std.mem.trim(u8, trimmed[open + 1 .. close], " ");
                if (self.event_handlers.get(handler_name) == null) return LowerError.UnknownHandler;
                const handler_export = try self.handlerExportName(handler_name);
                defer self.allocator.free(handler_export);
                const handler_idx = try self.string_pool.add(handler_export);
                const handler_const = try std.fmt.allocPrint(self.allocator, "sax_{s}_{d}", .{ self.component.name, handler_idx });
                defer self.allocator.free(handler_const);
                const delay_start = std.mem.indexOf(u8, trimmed, ",") orelse return LowerError.UnknownHandler;
                const delay = std.mem.trim(u8, trimmed[delay_start + 1 .. trimmed.len - 1], " ");
                try out.writer().print("  id = call @sax_set_timeout(*{s}, {}, {s})\n", .{ handler_const, handler_export.len, delay });
                continue;
            }
            try out.writer().print("{s}\n", .{trimmed});
        }
        try out.writer().writeByte('\n');
    }

    fn emitLifecycleDispatch(self: *const SaxLowerer, out: *std.ArrayList(u8), hook_name: []const u8) !void {
        for (self.component.lifecycle_hooks) |hook| {
            if (std.mem.eql(u8, hook.name, hook_name)) {
                const impl_name = try self.lifecycleImplName(hook_name);
                defer self.allocator.free(impl_name);
                try out.writer().print("  call @{s}(ctx)\n", .{impl_name});
                return;
            }
        }
    }

    fn emitRenderTrigger(self: *const SaxLowerer, out: *std.ArrayList(u8), include_update: bool) !void {
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        try out.writer().print("  call @sax_{s}_render(ctx)\n", .{stem});
        if (include_update) try self.emitLifecycleDispatch(out, "onUpdate");
    }

    fn stateSlotName(self: *const SaxLowerer, state_name: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ self.component.name, state_name });
    }

    fn lineStoresState(self: *const SaxLowerer, line: []const u8, state_name: []const u8) !bool {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "store state+")) return false;
        const slot_name = try self.stateSlotName(state_name);
        defer self.allocator.free(slot_name);
        const rest = trimmed["store state+".len..];
        if (!std.mem.startsWith(u8, rest, slot_name)) return false;
        if (rest.len == slot_name.len) return true;
        const next = rest[slot_name.len];
        return std.ascii.isWhitespace(next) or next == ',' or next == '+' or next == '-' or next == '(' or next == ')';
    }

    fn collectWrittenStates(self: *const SaxLowerer, body: []const u8) !std.StringHashMap(void) {
        var writes = std.StringHashMap(void).init(self.allocator);
        errdefer writes.deinit();

        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            for (self.component.state_vars) |sv| {
                if (try self.lineStoresState(line, sv.name)) {
                    try writes.put(sv.name, {});
                }
            }
        }

        return writes;
    }

    fn nodeUsesState(node: parser.DomNode, state_name: []const u8) bool {
        for (node.attrs) |attr| {
            switch (attr.value) {
                .literal => {},
                .interpolation => |expr| {
                    for (expr.deps) |dep| {
                        if (std.mem.eql(u8, dep, state_name)) return true;
                    }
                },
            }
        }
        for (node.children) |child| {
            switch (child) {
                .text => |piece| switch (piece) {
                    .text => {},
                    .interpolation => |expr| {
                        for (expr.deps) |dep| {
                            if (std.mem.eql(u8, dep, state_name)) return true;
                        }
                    },
                },
                .node_index => {},
            }
        }
        return false;
    }

    fn emitSelectiveRender(self: *SaxLowerer, out: *std.ArrayList(u8), writes: *std.StringHashMap(void)) !void {
        var emitted_any = false;
        for (self.component.dom_nodes, 0..) |node, idx| {
            var should_update = writes.count() == 0;
            if (!should_update) {
                for (self.component.state_vars) |sv| {
                    if (!writes.contains(sv.name)) continue;
                    if (SaxLowerer.nodeUsesState(node, sv.name)) {
                        should_update = true;
                        break;
                    }
                }
            }
            if (!should_update) continue;
            try self.emitNodeRender(out, "ctx", idx);
            emitted_any = true;
        }
        if (!emitted_any) {
            for (self.component.dom_nodes, 0..) |_, idx| {
                try self.emitNodeRender(out, "ctx", idx);
            }
        }
    }

    fn emitRenderAfterWrites(self: *SaxLowerer, out: *std.ArrayList(u8), body: []const u8, include_update: bool) !void {
        var writes = try self.collectWrittenStates(body);
        defer writes.deinit();
        try self.emitSelectiveRender(out, &writes);
        if (include_update) try self.emitLifecycleDispatch(out, "onUpdate");
    }

    fn emitInit(self: *SaxLowerer, out: *std.ArrayList(u8)) !void {
        const state_size_name = try self.stateSizeConstName();
        defer self.allocator.free(state_size_name);
        const dom_size_name = try self.domSizeConstName();
        defer self.allocator.free(dom_size_name);
        const ctx_size_name = try self.ctxSizeConstName();
        defer self.allocator.free(ctx_size_name);
        const ctx_state_name = try self.ctxStateOffsetConstName();
        defer self.allocator.free(ctx_state_name);
        const ctx_dom_name = try self.ctxDomOffsetConstName();
        defer self.allocator.free(ctx_dom_name);

        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        const impl_name = try self.initImplName();
        defer self.allocator.free(impl_name);
        try out.writer().print("@export sax_{s}_init() -> ptr:\nL_ENTRY:\n  ctx = call @{s}()\n  return ctx\n\n", .{ stem, impl_name });
        try out.writer().print("@ffi_wrapper {s}() -> ptr:\nL_ENTRY:\n", .{impl_name});
        try out.writer().print("  state = alloc {s}\n", .{state_size_name});
        for (self.component.state_vars, 0..) |sv, idx| {
            switch (sv.ty) {
                .ptr => {
                    const init_expr = std.mem.trim(u8, sv.init_expr, " \t\r");
                    if (std.mem.startsWith(u8, init_expr, "alloc ")) {
                        const sz = std.mem.trim(u8, init_expr["alloc ".len..], " \t\r");
                        try out.writer().print("  tmp_ptr_{d} = alloc {s}\n", .{ idx, sz });
                        const slot_name = try self.stateSlotConstName(sv.name);
                        defer self.allocator.free(slot_name);
                        try out.writer().print("  store state+{s}, tmp_ptr_{d} as ptr\n", .{ slot_name, idx });
                    } else {
                        const slot_name = try self.stateSlotConstName(sv.name);
                        defer self.allocator.free(slot_name);
                        try out.writer().print("  store state+{s}, 0 as ptr\n", .{slot_name});
                    }
                },
                .f64 => {
                    const slot_name = try self.stateSlotConstName(sv.name);
                    defer self.allocator.free(slot_name);
                    try out.writer().print("  store state+{s}, {d} as i64\n", .{ slot_name, try f64BitsLiteral(sv.init_expr, sv.ty) });
                },
                else => {
                    const slot_name = try self.stateSlotConstName(sv.name);
                    defer self.allocator.free(slot_name);
                    try out.writer().print("  store state+{s}, {s} as {s}\n", .{ slot_name, stateInitValueExpr(sv.init_expr, sv.ty), stateTypeName(sv.ty) });
                },
            }
        }

        try out.writer().print("  dom = alloc {s}\n", .{dom_size_name});
        try out.writer().print("  ctx = alloc {s}\n", .{ctx_size_name});
        try out.writer().print("  store ctx+{s}, state as ptr\n", .{ctx_state_name});
        try out.writer().print("  store ctx+{s}, dom as ptr\n", .{ctx_dom_name});

        const host_selector = try self.hostSelectorConstName();
        defer self.allocator.free(host_selector);
        try out.writer().print("  host = call @sax_dom_query(*{s}, 4)\n", .{host_selector});
        for (self.component.dom_nodes, 0..) |_, idx| {
            try self.emitNodeInit(out, "ctx", idx);
        }
        for (self.component.dom_nodes, 0..) |_, idx| {
            try self.emitNodeAttachChildren(out, idx);
        }
        for (self.component.root_nodes) |root_idx| {
            const root_var = try std.fmt.allocPrint(self.allocator, "node_{d}", .{root_idx});
            defer self.allocator.free(root_var);
            try out.writer().print("  call @sax_dom_append_child(host, {s})\n", .{root_var});
        }
        try self.emitRenderTrigger(out, false);
        try self.emitLifecycleDispatch(out, "onMount");
        try out.writer().writeAll("  return ctx\n\n");
    }

    fn emitRender(self: *SaxLowerer, out: *std.ArrayList(u8)) !void {
        const ctx_state_name = try self.ctxStateOffsetConstName();
        defer self.allocator.free(ctx_state_name);
        const ctx_dom_name = try self.ctxDomOffsetConstName();
        defer self.allocator.free(ctx_dom_name);

        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        const impl_name = try self.renderImplName();
        defer self.allocator.free(impl_name);
        try out.writer().print("@export sax_{s}_render(ctx: ptr):\nL_ENTRY:\n  call @{s}(ctx)\n  return\n\n", .{ stem, impl_name });
        try out.writer().print("@ffi_wrapper {s}(ctx: ptr):\nL_ENTRY:\n", .{impl_name});
        try out.writer().print("  state = load ctx+{s} as ptr\n", .{ctx_state_name});
        try out.writer().print("  dom = load ctx+{s} as ptr\n", .{ctx_dom_name});
        for (self.component.dom_nodes, 0..) |_, idx| {
            try self.emitNodeRender(out, "ctx", idx);
        }
        try out.writer().writeAll("  return\n\n");
    }

    fn emitDestroy(self: *const SaxLowerer, out: *std.ArrayList(u8)) !void {
        const ctx_state_name = try self.ctxStateOffsetConstName();
        defer self.allocator.free(ctx_state_name);
        const ctx_dom_name = try self.ctxDomOffsetConstName();
        defer self.allocator.free(ctx_dom_name);

        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        const impl_name = try self.destroyImplName();
        defer self.allocator.free(impl_name);
        try out.writer().print("@export sax_{s}_destroy(ctx: ptr):\nL_ENTRY:\n  call @{s}(ctx)\n  return\n\n", .{ stem, impl_name });
        try out.writer().print("@ffi_wrapper {s}(ctx: ptr):\nL_ENTRY:\n", .{impl_name});
        try out.writer().print("  state = load ctx+{s} as ptr\n", .{ctx_state_name});
        try out.writer().print("  dom = load ctx+{s} as ptr\n", .{ctx_dom_name});
        try self.emitLifecycleDispatch(out, "onUnmount");
        for (self.component.dom_nodes, 0..) |node, idx| {
            const node_slot = try self.nodeSlotConstName(node.alias);
            defer self.allocator.free(node_slot);
            const node_var = try std.fmt.allocPrint(self.allocator, "node_{d}", .{idx});
            defer self.allocator.free(node_var);
            try out.writer().print("  {s} = load dom+{s} as ptr\n", .{ node_var, node_slot });
            try out.writer().print("  call @sax_dom_remove_self({s})\n", .{node_var});
        }
        for (self.component.release_vars) |release_name| {
            try self.emitLoadState(out, release_name, release_name);
            try out.writer().print("  !{s}\n", .{release_name});
        }
        try out.writer().writeAll("  !dom\n  !state\n  !ctx\n");
        try out.writer().writeAll("  return\n\n");
    }

    fn emitRouterInit(self: *const SaxLowerer, out: *std.ArrayList(u8)) !void {
        if (self.component.route_pages.len == 0) return;
        const stem = try self.componentStem();
        defer self.allocator.free(stem);
        const router_path_name = try std.fmt.allocPrint(self.allocator, "sax_{s}_route_path", .{self.component.name});
        defer self.allocator.free(router_path_name);

        const impl_name = try self.routerInitImplName();
        defer self.allocator.free(impl_name);
        try out.writer().print("@export sax_{s}_router_init(path: ptr):\nL_ENTRY:\n  call @{s}(path)\n  return\n\n", .{ stem, impl_name });
        try out.writer().print("@ffi_wrapper {s}(path: ptr):\nL_ENTRY:\n", .{impl_name});
        try out.writer().print("  call @sax_router_replace(*{s}, {})\n", .{ router_path_name, self.component.route_pages[0].path.len });
        try out.writer().print("  call @sax_router_init(*{s}, {})\n", .{ router_path_name, self.component.route_pages[0].path.len });
        try out.writer().writeAll("  return\n\n");
    }

    pub fn lower(self: *SaxLowerer, out: *std.ArrayList(u8), options: LowerOptions) !void {
        const state_size_name = try self.stateSizeConstName();
        defer self.allocator.free(state_size_name);
        const dom_size_name = try self.domSizeConstName();
        defer self.allocator.free(dom_size_name);
        const ctx_size_name = try self.ctxSizeConstName();
        defer self.allocator.free(ctx_size_name);
        const ctx_state_name = try self.ctxStateOffsetConstName();
        defer self.allocator.free(ctx_state_name);
        const ctx_dom_name = try self.ctxDomOffsetConstName();
        defer self.allocator.free(ctx_dom_name);

        try out.writer().print("#def {s} = {}\n", .{ state_size_name, self.stateAllocSize() });
        try out.writer().print("#def {s} = {}\n", .{ dom_size_name, self.domAllocSize() });
        try out.writer().print("#def {s} = 16\n", .{ctx_size_name});
        try out.writer().print("#def {s} = +0\n", .{ctx_state_name});
        try out.writer().print("#def {s} = +8\n\n", .{ctx_dom_name});

        for (self.component.state_vars, 0..) |sv, idx| {
            const slot_name = try self.stateSlotConstName(sv.name);
            defer self.allocator.free(slot_name);
            try out.writer().print("#def {s} = +{}\n", .{ slot_name, self.state_slots[idx].offset });
        }
        if (self.component.state_vars.len != 0) try out.writer().writeByte('\n');

        for (self.component.dom_nodes, 0..) |node, idx| {
            const slot_name = try self.nodeSlotConstName(node.alias);
            defer self.allocator.free(slot_name);
            try out.writer().print("#def {s} = +{}\n", .{ slot_name, self.node_slots[idx].handle_slot * 8 });
        }
        if (self.component.dom_nodes.len != 0) try out.writer().writeByte('\n');

        if (options.emit_shared_decls) try self.appendExternDecls(out);
        try self.appendStdImports(out);
        try self.appendArrayAdapter(out);
        try self.emitInit(out);
        try self.emitRender(out);
        try self.emitRouterInit(out);
        for (self.component.lifecycle_hooks) |hook| {
            try self.emitLifecycleHook(out, hook);
        }
        for (self.component.handlers) |handler| {
            try self.emitHandler(out, handler);
        }
        try self.emitDestroy(out);
        try self.appendConstDecls(out);
    }
};

test "lowerer emits counter-shaped sa for the docs example" {
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

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "#def Counter_count = +0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "#def Counter_last = +8"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@extern sax_dom_bind_event"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "utf8:\"click\""));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "utf8:\"onclick\"") == null);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "call @sax_dom_append_child(host, node_0)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@export sax_counter_inc(ctx: ptr):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@export sax_counter_render(ctx: ptr):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@export sax_counter_destroy(ctx: ptr):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "  return\n\n"));
}

test "lowerer emits lifecycle hooks for docs phase 2 shapes" {
    const source =
        \\<Component name="TimerWidget">
        \\  <state>
        \\    tick = 0
        \\    timer_id = 0
        \\  </state>
        \\  <div><p>Tick: {tick}</p></div>
        \\  @onMount:
        \\  L_ENTRY:
        \\    id = call @sax_set_interval(^onTick, 1000)
        \\    store state+TimerWidget_timer_id, id as i64
        \\    ret
        \\  @onUnmount:
        \\  L_ENTRY:
        \\    id = load state+TimerWidget_timer_id as i64
        \\    call @sax_clear_interval(id)
        \\    ret
        \\  @onTick:
        \\  L_ENTRY:
        \\    tick = load state+TimerWidget_tick as i64
        \\    tick = add tick, 1
        \\    store state+TimerWidget_tick, tick as i64
        \\    call @render()
        \\    ret
        \\  !tick !timer_id
        \\</Component>
    ;

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@extern sax_set_interval"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@extern sax_clear_interval"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@export sax_timerwidget_onMount(ctx: ptr):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@export sax_timerwidget_onUnmount(ctx: ptr):"));
}

test "lowerer emits onUpdate after render triggers" {
    const source =
        \\<Component name="Updater">
        \\  <state>
        \\    count = 0
        \\  </state>
        \\  <div><button onclick={^inc}>+</button><p>{count}</p></div>
        \\  @inc:
        \\  L_ENTRY:
        \\    count = load state+Updater_count as i64
        \\    count = add count, 1
        \\    store state+Updater_count, count as i64
        \\    call @render()
        \\    ret
        \\  @onUpdate:
        \\  L_ENTRY:
        \\    call @sax_get_time()
        \\    ret
        \\  !count
        \\</Component>
    ;

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@export sax_updater_onUpdate(ctx: ptr):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "call @sax_get_time()"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "call @sax_updater_render(ctx)"));
}

test "lowerer keeps alloc state buffers on the heap" {
    const source =
        \\<Component name="BufferLab">
        \\  <state>
        \\    scratch = alloc 32
        \\    writes = 0
        \\  </state>
        \\  <section><p>{writes}</p></section>
        \\  !scratch !writes
        \\</Component>
    ;

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "tmp_ptr_0 = alloc 32"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "tmp_ptr_0 = stack_alloc 32") == null);
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "store state+BufferLab_scratch, tmp_ptr_0 as ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "scratch = load state+BufferLab_scratch as ptr"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "!scratch"));
}

test "lowerer emits read-only arithmetic for interpolation expressions" {
    const source =
        \\<Component name="ExprLab">
        \\  <state>
        \\    count = 7
        \\    label = 5
        \\  </state>
        \\  <section>
        \\    <p>Total: {count + label * 2}</p>
        \\    <input value="{(count + label * 2) / 3}" />
        \\  </section>
        \\  !count !label
        \\</Component>
    ;

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = load state+ExprLab_count as i64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = load state+ExprLab_label as i64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = mul "));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = add "));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = sdiv "));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "call @sax_itoa("));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "load state+ExprLab_count + label") == null);
}

test "lowerer preserves typed state init and interpolation formatting" {
    const source =
        \\<Component name="TypedLab">
        \\  <state>
        \\    score = 7 as i32
        \\    active = 1 as i1
        \\    ratio = 0.75 as f64
        \\  </state>
        \\  <section>
        \\    <p>{score}</p>
        \\    <p>{active}</p>
        \\    <p>{ratio}</p>
        \\  </section>
        \\  !score !active !ratio
        \\</Component>
    ;

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "store state+TypedLab_score, 7 as i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "store state+TypedLab_active, 1 as i1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "store state+TypedLab_ratio, 4604930618986332160 as i64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = load state+TypedLab_score as i32"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = sext "));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = load state+TypedLab_active as i1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = zext "));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, " = load state+TypedLab_ratio as i64"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "call @sax_ftoa_bits("));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "as i32 as i32") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "as i1 as i1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "as f64 as f64") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "load state+TypedLab_ratio as f64") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "bitcast ") == null);
}

test "lowerer emits selective render for state writes" {
    const source =
        \\<Component name="Selective">
        \\  <state>
        \\    count = 0
        \\    label = 0
        \\  </state>
        \\  <div>
        \\    <h1>{count}</h1>
        \\    <p>{label}</p>
        \\  </div>
        \\  @inc:
        \\  L_ENTRY:
        \\    count = load state+Selective_count as i64
        \\    count = add count, 1
        \\    store state+Selective_count, count as i64
        \\    call @render()
        \\    ret
        \\  !count !label
        \\</Component>
    ;

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "call @sax_selective_render(ctx)"));
    const inc_start = std.mem.indexOf(u8, out.items, "@ffi_wrapper sax_selective_inc_ffi(ctx: ptr):") orelse unreachable;
    const inc_end = std.mem.indexOf(u8, out.items[inc_start..], "@export sax_selective_destroy(ctx: ptr):") orelse out.items.len - inc_start;
    const inc_block = out.items[inc_start .. inc_start + inc_end];
    try std.testing.expect(std.mem.containsAtLeast(u8, inc_block, 1, "call @sax_dom_set_text(node_1, *"));
    try std.testing.expect(std.mem.indexOf(u8, inc_block, "call @sax_dom_set_text(node_2, *") == null);
}

test "lowerer emits router metadata and init when pages are present" {
    const source =
        \\<Component name="App">
        \\  <Router>
        \\    <Page path="/" component="HomePage" />
        \\    <Page path="/about" component="AboutPage" />
        \\  </Router>
        \\</Component>
    ;

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@const sax_App_route_path_0 = utf8:\"/\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@const sax_App_route_component_0 = utf8:\"HomePage\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@export sax_app_router_init(path: ptr):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@extern sax_router_init"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "call @sax_router_init(*"));
}

test "lowerer emits ffi wrapper bridge for handlers" {
    const source =
        \\<Component name="Bridge">
        \\  <div></div>
        \\  @ffi_wrapper call_dom:
        \\  L_ENTRY:
        \\    raw = *state
        \\    return raw
        \\</Component>
    ;

    var sax_parser = parser.SaxParser.init(std.testing.allocator, source);
    var program = try sax_parser.parse();
    defer program.deinit();

    var lowerer = try SaxLowerer.init(std.testing.allocator, program.components[0]);
    defer lowerer.deinit();

    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try lowerer.lower(&out, .{});

    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@ffi_wrapper sax_bridge_call_dom_ffi(ctx: ptr):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out.items, 1, "@export sax_bridge_call_dom(ctx: ptr):"));
}
