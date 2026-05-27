const std = @import("std");
const upstream = @import("upstream_loc.zig");

pub const ConstLiteralKind = enum(u8) {
    hex,
    utf8,
    repeat,
    struct_,
    vtable,
};

pub const BytesLiteral = struct {
    kind: ConstLiteralKind,
    bytes: []u8,
    repeat_count: ?u64 = null,
    repeat_byte: ?u8 = null,

    pub fn deinit(self: *BytesLiteral, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const VTableSlot = struct {
    name: []u8,
    func_name: []u8,

    pub fn deinit(self: *VTableSlot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.func_name);
        self.* = undefined;
    }
};

pub const StructField = struct {
    name: []u8,
    size: u64,
    value: ConstValue,

    pub fn deinit(self: *StructField, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const StructLiteral = struct {
    fields: []StructField,

    pub fn deinit(self: *StructLiteral, allocator: std.mem.Allocator) void {
        for (self.fields) |*field| field.deinit(allocator);
        allocator.free(self.fields);
        self.* = undefined;
    }
};

pub const VTableLiteral = struct {
    slots: []VTableSlot,

    pub fn deinit(self: *VTableLiteral, allocator: std.mem.Allocator) void {
        for (self.slots) |*slot| slot.deinit(allocator);
        allocator.free(self.slots);
        self.* = undefined;
    }
};

pub const ConstValue = union(ConstLiteralKind) {
    hex: BytesLiteral,
    utf8: BytesLiteral,
    repeat: BytesLiteral,
    struct_: StructLiteral,
    vtable: VTableLiteral,

    pub fn deinit(self: *ConstValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .hex => |*literal| literal.deinit(allocator),
            .utf8 => |*literal| literal.deinit(allocator),
            .repeat => |*literal| literal.deinit(allocator),
            .struct_ => |*literal| literal.deinit(allocator),
            .vtable => |*literal| literal.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ConstDecl = struct {
    source_line: u32,
    expanded_line: u32,
    upstream_loc: ?upstream.UpstreamLoc = null,
    raw_text: []u8,
    name: []u8,
    literal_text: []u8,
    value: ConstValue,

    pub fn deinit(self: *ConstDecl, allocator: std.mem.Allocator) void {
        if (self.upstream_loc) |loc| allocator.free(loc.file);
        allocator.free(self.raw_text);
        allocator.free(self.name);
        allocator.free(self.literal_text);
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

pub const ParseError = error{
    OutOfMemory,
    InvalidConstDecl,
    InvalidLiteral,
    InvalidUtf8,
    DuplicateSlot,
    EmptySlotName,
    EmptyFunctionName,
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r");
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn startsWithWord(s: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, s, word)) return false;
    if (s.len == word.len) return true;
    const next = s[word.len];
    return std.ascii.isWhitespace(next) or next == '{' or next == '(' or next == '[' or next == ':' or next == '=' or next == '@' or next == '-';
}

fn parseIdent(text: []const u8) ?[]const u8 {
    const t = trim(text);
    if (t.len == 0 or !isIdentStart(t[0])) return null;
    for (t[1..]) |c| {
        if (!isIdentChar(c)) return null;
    }
    return t;
}

fn parseHexDigitPair(text: []const u8) ParseError!u8 {
    if (text.len != 2) return ParseError.InvalidLiteral;
    const hi = std.fmt.charToDigit(text[0], 16) catch return ParseError.InvalidLiteral;
    const lo = std.fmt.charToDigit(text[1], 16) catch return ParseError.InvalidLiteral;
    return @as(u8, @intCast((hi << 4) | lo));
}

fn parseByteToken(text: []const u8) ParseError!u8 {
    const t = trim(text);
    if (t.len == 0) return ParseError.InvalidLiteral;

    if (std.mem.startsWith(u8, t, "0x")) {
        const digits = t[2..];
        if (digits.len == 0 or digits.len > 2) return ParseError.InvalidLiteral;
        return std.fmt.parseInt(u8, digits, 16) catch return ParseError.InvalidLiteral;
    }

    if (std.mem.startsWith(u8, t, "\\x")) {
        return parseHexDigitPair(t[2..]);
    }

    if (t.len == 3 and t[0] == '\'' and t[2] == '\'') {
        return t[1];
    }

    return std.fmt.parseInt(u8, t, 10) catch ParseError.InvalidLiteral;
}

fn findTopLevelChar(text: []const u8, needle: u8) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    for (text, 0..) |c, idx| {
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            switch (c) {
                '\\' => escape = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
            },
            else => {},
        }

        if (depth == 0 and c == needle) return idx;
    }
    if (in_string or depth != 0) return null;
    return null;
}

fn splitTopLevelCommaSegments(allocator: std.mem.Allocator, text: []const u8) ParseError![]const []const u8 {
    const trimmed = trim(text);
    if (trimmed.len == 0) return try allocator.alloc([]const u8, 0);

    var list = std.ArrayList([]const u8).init(allocator);
    errdefer list.deinit();

    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var start: usize = 0;

    for (trimmed, 0..) |c, idx| {
        if (in_string) {
            if (escape) {
                escape = false;
                continue;
            }
            switch (c) {
                '\\' => escape = true,
                '"' => in_string = false,
                else => {},
            }
            continue;
        }

        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return ParseError.InvalidLiteral;
                depth -= 1;
            },
            ',' => if (depth == 0) {
                const segment = trim(trimmed[start..idx]);
                if (segment.len == 0) return ParseError.InvalidLiteral;
                try list.append(segment);
                start = idx + 1;
            },
            else => {},
        }
    }

    if (in_string or depth != 0) return ParseError.InvalidLiteral;

    const tail = trim(trimmed[start..]);
    if (tail.len == 0) return ParseError.InvalidLiteral;
    try list.append(tail);
    return try list.toOwnedSlice();
}

fn decodeQuotedBytes(allocator: std.mem.Allocator, raw: []const u8) ParseError![]u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
        return ParseError.InvalidLiteral;
    }

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

        if (i + 1 >= raw.len - 1) return ParseError.InvalidLiteral;
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
                if (i + 3 >= raw.len - 1) return ParseError.InvalidLiteral;
                try out.append(try parseHexDigitPair(raw[i + 2 .. i + 4]));
                i += 4;
            },
            else => return ParseError.InvalidLiteral,
        }
    }

    return try out.toOwnedSlice();
}

fn parseHexBytes(allocator: std.mem.Allocator, literal: []const u8) ParseError!BytesLiteral {
    const body = trim(literal);
    if (body.len == 0) {
        return .{ .kind = .hex, .bytes = try allocator.alloc(u8, 0) };
    }
    if (body.len % 4 != 0) return ParseError.InvalidLiteral;

    var bytes = std.ArrayList(u8).init(allocator);
    errdefer bytes.deinit();

    var i: usize = 0;
    while (i < body.len) : (i += 4) {
        if (body[i] != '\\' or body[i + 1] != 'x') return ParseError.InvalidLiteral;
        try bytes.append(try parseHexDigitPair(body[i + 2 .. i + 4]));
    }

    return .{
        .kind = .hex,
        .bytes = try bytes.toOwnedSlice(),
    };
}

fn parseUtf8Bytes(allocator: std.mem.Allocator, literal: []const u8) ParseError!BytesLiteral {
    const body = trim(literal);
    const bytes = try decodeQuotedBytes(allocator, body);
    errdefer allocator.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return ParseError.InvalidUtf8;
    return .{
        .kind = .utf8,
        .bytes = bytes,
    };
}

fn parseRepeatBytes(allocator: std.mem.Allocator, literal: []const u8) ParseError!BytesLiteral {
    const body = trim(literal);
    const of_idx = std.mem.indexOf(u8, body, " of ") orelse return ParseError.InvalidLiteral;
    const count_text = trim(body[0..of_idx]);
    const byte_text = trim(body[of_idx + 4 ..]);
    const count = std.fmt.parseInt(u64, count_text, 10) catch return ParseError.InvalidLiteral;
    const byte = try parseByteToken(byte_text);
    const count_usize = std.math.cast(usize, count) orelse return ParseError.InvalidLiteral;
    const bytes = try allocator.alloc(u8, count_usize);
    @memset(bytes, byte);
    return .{
        .kind = .repeat,
        .bytes = bytes,
        .repeat_count = count,
        .repeat_byte = byte,
    };
}

fn valueByteLen(value: ConstValue) ParseError!u64 {
    return switch (value) {
        .hex => |literal| @as(u64, @intCast(literal.bytes.len)),
        .utf8 => |literal| @as(u64, @intCast(literal.bytes.len)),
        .repeat => |literal| @as(u64, @intCast(literal.bytes.len)),
        .vtable => |literal| @as(u64, @intCast(literal.slots.len)) * 8,
        .struct_ => |literal| blk: {
            var total: u64 = 0;
            for (literal.fields) |field| {
                const field_len = try valueByteLen(field.value);
                if (field_len != field.size) return ParseError.InvalidLiteral;
                total = std.math.add(u64, total, field_len) catch return ParseError.InvalidLiteral;
            }
            break :blk total;
        },
    };
}

fn parseStruct(allocator: std.mem.Allocator, literal_text: []const u8) ParseError!StructLiteral {
    const trimmed = trim(literal_text);
    if (!startsWithWord(trimmed, "struct")) return ParseError.InvalidLiteral;
    const open = std.mem.indexOfScalar(u8, trimmed, '{') orelse return ParseError.InvalidLiteral;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return ParseError.InvalidLiteral;
    if (close <= open or trim(trimmed[close + 1 ..]).len != 0) return ParseError.InvalidLiteral;

    const body = trim(trimmed[open + 1 .. close]);
    if (body.len == 0) {
        return .{ .fields = try allocator.alloc(StructField, 0) };
    }

    const segments = try splitTopLevelCommaSegments(allocator, body);
    defer allocator.free(segments);

    var fields = std.ArrayList(StructField).init(allocator);
    errdefer {
        for (fields.items) |*field| field.deinit(allocator);
        fields.deinit();
    }

    for (segments) |segment| {
        const colon = std.mem.indexOfScalar(u8, segment, ':') orelse return ParseError.InvalidLiteral;
        const name = parseIdent(segment[0..colon]) orelse return ParseError.InvalidLiteral;
        const rest = trim(segment[colon + 1 ..]);
        const eq = findTopLevelChar(rest, '=') orelse return ParseError.InvalidLiteral;
        const size_text = trim(rest[0..eq]);
        const value_text = trim(rest[eq + 1 ..]);
        if (size_text.len == 0 or value_text.len == 0) return ParseError.InvalidLiteral;

        const size = std.fmt.parseInt(u64, size_text, 10) catch return ParseError.InvalidLiteral;
        const value = try parseValue(allocator, value_text);
        const actual = try valueByteLen(value);
        if (actual != size) {
            var owned_value = value;
            owned_value.deinit(allocator);
            return ParseError.InvalidLiteral;
        }

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        try fields.append(.{
            .name = name_copy,
            .size = size,
            .value = value,
        });
    }

    return .{ .fields = try fields.toOwnedSlice() };
}

fn parseValue(allocator: std.mem.Allocator, literal_text: []const u8) ParseError!ConstValue {
    const trimmed = trim(literal_text);
    if (startsWithWord(trimmed, "struct")) {
        return .{ .struct_ = try parseStruct(allocator, trimmed) };
    }
    if (startsWithWord(trimmed, "vtable")) {
        return .{ .vtable = try parseVTable(allocator, trimmed) };
    }
    if (std.mem.startsWith(u8, trimmed, "hex:")) {
        return .{ .hex = try parseHexBytes(allocator, trimmed["hex:".len..]) };
    }
    if (std.mem.startsWith(u8, trimmed, "utf8:")) {
        return .{ .utf8 = try parseUtf8Bytes(allocator, trimmed["utf8:".len..]) };
    }
    if (std.mem.startsWith(u8, trimmed, "repeat:")) {
        return .{ .repeat = try parseRepeatBytes(allocator, trimmed["repeat:".len..]) };
    }
    return ParseError.InvalidLiteral;
}

fn parseVTable(allocator: std.mem.Allocator, literal_text: []const u8) ParseError!VTableLiteral {
    const trimmed = trim(literal_text);
    if (!startsWithWord(trimmed, "vtable")) return ParseError.InvalidLiteral;
    const open = std.mem.indexOfScalar(u8, trimmed, '{') orelse return ParseError.InvalidLiteral;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, '}') orelse return ParseError.InvalidLiteral;
    if (close <= open or trim(trimmed[close + 1 ..]).len != 0) return ParseError.InvalidLiteral;

    const body = trim(trimmed[open + 1 .. close]);
    if (body.len == 0) {
        return .{ .slots = try allocator.alloc(VTableSlot, 0) };
    }

    const segments = try splitTopLevelCommaSegments(allocator, body);
    defer allocator.free(segments);

    var slots = std.ArrayList(VTableSlot).init(allocator);
    errdefer {
        for (slots.items) |*slot| slot.deinit(allocator);
        slots.deinit();
    }

    for (segments) |fragment| {
        const eq = findTopLevelChar(fragment, '=') orelse return ParseError.InvalidLiteral;
        const slot_name = parseIdent(fragment[0..eq]) orelse return ParseError.InvalidLiteral;
        const func_text = trim(fragment[eq + 1 ..]);
        if (func_text.len < 2 or func_text[0] != '@') return ParseError.InvalidLiteral;
        const func_name = parseIdent(func_text[1..]) orelse return ParseError.InvalidLiteral;

        for (slots.items) |existing| {
            if (std.mem.eql(u8, existing.name, slot_name)) return ParseError.InvalidLiteral;
        }

        const slot_name_copy = try allocator.dupe(u8, slot_name);
        errdefer allocator.free(slot_name_copy);
        const func_name_copy = try allocator.dupe(u8, func_name);
        errdefer allocator.free(func_name_copy);
        try slots.append(.{
            .name = slot_name_copy,
            .func_name = func_name_copy,
        });
    }

    return .{ .slots = try slots.toOwnedSlice() };
}

pub fn parseConstDecl(
    allocator: std.mem.Allocator,
    raw_line: []const u8,
    source_line: u32,
    expanded_line: u32,
    upstream_loc: ?upstream.UpstreamLoc,
) ParseError!ConstDecl {
    const trimmed = trim(raw_line);
    if (!startsWithWord(trimmed, "@const")) return ParseError.InvalidConstDecl;

    const body = trim(trimmed["@const".len..]);
    const eq = std.mem.indexOfScalar(u8, body, '=') orelse return ParseError.InvalidConstDecl;
    const name = parseIdent(body[0..eq]) orelse return ParseError.InvalidConstDecl;
    const literal_text = trim(body[eq + 1 ..]);
    if (literal_text.len == 0) return ParseError.InvalidLiteral;

    const raw_copy = try allocator.dupe(u8, raw_line);
    errdefer allocator.free(raw_copy);
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);
    const literal_copy = try allocator.dupe(u8, literal_text);
    errdefer allocator.free(literal_copy);

    const value = try parseValue(allocator, literal_text);

    return .{
        .source_line = source_line,
        .expanded_line = expanded_line,
        .upstream_loc = upstream_loc,
        .raw_text = raw_copy,
        .name = name_copy,
        .literal_text = literal_copy,
        .value = value,
    };
}

test "parse top-level const declarations" {
    var bytes = try parseConstDecl(std.testing.allocator, "@const HELLO = utf8:\"hello\"", 7, 3, null);
    defer bytes.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 7), bytes.source_line);
    try std.testing.expectEqualStrings("HELLO", bytes.name);
    try std.testing.expectEqualStrings("utf8:\"hello\"", bytes.literal_text);
    switch (bytes.value) {
        .utf8 => |literal| {
            try std.testing.expectEqual(ConstLiteralKind.utf8, literal.kind);
            try std.testing.expectEqualStrings("hello", literal.bytes);
        },
        else => return error.TestUnexpectedResult,
    }

    var vt = try parseConstDecl(std.testing.allocator, "@const CIRCLE_VT = vtable { draw = @Circle_draw, drop = @Circle_drop }", 8, 4, null);
    defer vt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("CIRCLE_VT", vt.name);
    switch (vt.value) {
        .vtable => |literal| {
            try std.testing.expectEqual(@as(usize, 2), literal.slots.len);
            try std.testing.expectEqualStrings("draw", literal.slots[0].name);
            try std.testing.expectEqualStrings("Circle_draw", literal.slots[0].func_name);
        },
        else => return error.TestUnexpectedResult,
    }

    var st = try parseConstDecl(
        std.testing.allocator,
        "@const PAIR = struct { first: 2 = hex:\\x01\\x02, second: 3 = utf8:\"hey\" }",
        9,
        5,
        null,
    );
    defer st.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("PAIR", st.name);
    switch (st.value) {
        .struct_ => |literal| {
            try std.testing.expectEqual(@as(usize, 2), literal.fields.len);
            try std.testing.expectEqualStrings("first", literal.fields[0].name);
            try std.testing.expectEqual(@as(u64, 2), literal.fields[0].size);
            try std.testing.expectEqualStrings("second", literal.fields[1].name);
            try std.testing.expectEqual(@as(u64, 3), literal.fields[1].size);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectError(
        ParseError.InvalidLiteral,
        parseConstDecl(std.testing.allocator, "@const BAD = struct { x: 2 = hex:\\x01 }", 10, 6, null),
    );
}
