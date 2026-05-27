const std = @import("std");

pub const DefError = error{
    OutOfMemory,
    DuplicateDef,
    UnknownDef,
    InvalidExpression,
    RecursionLimit,
};

pub const DefDict = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) DefDict {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *DefDict) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn putExpression(self: *DefDict, name: []const u8, expr: []const u8) DefError!void {
        if (self.entries.contains(name)) return DefError.DuplicateDef;

        const value = try self.evalExpression(std.mem.trim(u8, stripInlineComment(expr), " \t\r"), 0);
        const key_copy = try self.allocator.dupe(u8, name);
        const value_copy = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        errdefer self.allocator.free(key_copy);
        errdefer self.allocator.free(value_copy);
        try self.entries.put(key_copy, value_copy);
    }

    pub fn get(self: *const DefDict, name: []const u8) ?[]const u8 {
        return self.entries.get(name);
    }

    pub fn resolveToken(self: *const DefDict, token: []const u8) ?[]const u8 {
        return self.get(token) orelse token;
    }

    pub fn foldToken(self: *const DefDict, token: []const u8) ![]const u8 {
        const resolved = self.resolveToken(token) orelse return token;
        return resolved;
    }

    pub fn foldText(self: *const DefDict, allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        if (self.entries.count() == 0) {
            return try allocator.dupe(u8, text);
        }

        // Fast path: check if any key exists in the text.
        var has_replacement = false;
        var i_fast: usize = 0;
        while (i_fast < text.len) {
            if (std.ascii.isAlphabetic(text[i_fast]) or text[i_fast] == '_') {
                const start = i_fast;
                i_fast += 1;
                while (i_fast < text.len and (std.ascii.isAlphanumeric(text[i_fast]) or text[i_fast] == '_' or text[i_fast] == '.')) : (i_fast += 1) {}
                const token = text[start..i_fast];
                if (self.entries.contains(token)) {
                    has_replacement = true;
                    break;
                }
            } else {
                i_fast += 1;
            }
        }

        if (!has_replacement) {
            return try allocator.dupe(u8, text);
        }

        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();

        var i: usize = 0;
        while (i < text.len) {
            if (std.ascii.isAlphabetic(text[i]) or text[i] == '_') {
                const start = i;
                i += 1;
                while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '.')) : (i += 1) {}
                const token = text[start..i];
                if (self.get(token)) |replacement| {
                    try out.appendSlice(replacement);
                } else {
                    try out.appendSlice(token);
                }
            } else {
                try out.append(text[i]);
                i += 1;
            }
        }

        return try out.toOwnedSlice();
    }

    fn skipSpaces(text: []const u8, pos: *usize) void {
        while (pos.* < text.len and std.ascii.isWhitespace(text[pos.*])) : (pos.* += 1) {}
    }

    fn stripInlineComment(line: []const u8) []const u8 {
        var in_string = false;
        var escape = false;
        var i: usize = 0;
        while (i + 1 < line.len) : (i += 1) {
            const c = line[i];
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
                '/' => {
                    if (line[i + 1] == '/') {
                        const prev = if (i == 0) ' ' else line[i - 1];
                        if (i == 0 or std.ascii.isWhitespace(prev)) return line[0..i];
                    }
                },
                else => {},
            }
        }
        return line;
    }

    fn parseNumber(text: []const u8, pos: *usize) ?i64 {
        const start = pos.*;
        var i = start;
        var negative = false;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        if (text[start] == '-') negative = true;

        var radix: u8 = 10;
        if (i + 1 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
            radix = 16;
            i += 2;
        }

        const digits_start = i;
        var has_digit = false;
        while (i < text.len) : (i += 1) {
            if (radix == 10) {
                if (!std.ascii.isDigit(text[i])) break;
            } else {
                if (!std.ascii.isHex(text[i])) break;
            }
            has_digit = true;
        }
        if (!has_digit) return null;

        const digits = text[digits_start..i];
        pos.* = i;

        if (negative) {
            if (radix == 16) {
                const unsigned = std.fmt.parseInt(u64, digits, 16) catch return null;
                if (unsigned == @as(u64, @intCast(std.math.maxInt(i64))) + 1) return std.math.minInt(i64);
                if (unsigned <= @as(u64, @intCast(std.math.maxInt(i64)))) {
                    const positive: i64 = @intCast(unsigned);
                    return -positive;
                }
                return null;
            }
            return std.fmt.parseInt(i64, text[start..i], 10) catch null;
        }

        if (radix == 16) {
            const unsigned = std.fmt.parseInt(u64, digits, 16) catch return null;
            return @bitCast(unsigned);
        }

        return std.fmt.parseInt(i64, text[start..i], 10) catch |err| switch (err) {
            error.Overflow => blk: {
                const unsigned = std.fmt.parseInt(u64, digits, 10) catch return null;
                break :blk @bitCast(unsigned);
            },
            else => null,
        };
    }

    fn parseIdentifier(text: []const u8, pos: *usize) ?[]const u8 {
        const start = pos.*;
        if (start >= text.len) return null;
        const first = text[start];
        if (!(std.ascii.isAlphabetic(first) or first == '_')) return null;
        var i = start + 1;
        while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_' or text[i] == '.')) : (i += 1) {}
        const ident = text[start..i];
        if (!isQualifiedIdent(ident)) return null;
        pos.* = i;
        return ident;
    }

    fn isQualifiedIdent(text: []const u8) bool {
        if (text.len == 0) return false;
        if (text[0] == '.' or text[text.len - 1] == '.') return false;

        var segment_start: usize = 0;
        var idx: usize = 0;
        while (idx < text.len) : (idx += 1) {
            if (text[idx] != '.') continue;
            if (idx == segment_start) return false;
            if (!(std.ascii.isAlphabetic(text[segment_start]) or text[segment_start] == '_')) return false;
            var seg_idx = segment_start + 1;
            while (seg_idx < idx) : (seg_idx += 1) {
                if (!(std.ascii.isAlphanumeric(text[seg_idx]) or text[seg_idx] == '_')) return false;
            }
            segment_start = idx + 1;
        }

        if (segment_start >= text.len) return false;
        if (!(std.ascii.isAlphabetic(text[segment_start]) or text[segment_start] == '_')) return false;
        var seg_idx = segment_start + 1;
        while (seg_idx < text.len) : (seg_idx += 1) {
            if (!(std.ascii.isAlphanumeric(text[seg_idx]) or text[seg_idx] == '_')) return false;
        }
        return true;
    }

    fn parsePrimary(self: *const DefDict, text: []const u8, pos: *usize, depth: u8) DefError!i64 {
        skipSpaces(text, pos);
        if (pos.* >= text.len) return DefError.InvalidExpression;

        if (text[pos.*] == '(') {
            pos.* += 1;
            const value = try self.parseAddSub(text, pos, depth + 1);
            skipSpaces(text, pos);
            if (pos.* >= text.len or text[pos.*] != ')') return DefError.InvalidExpression;
            pos.* += 1;
            return value;
        }

        if (text[pos.*] == '-') {
            pos.* += 1;
            return -try self.parsePrimary(text, pos, depth + 1);
        }

        if (parseNumber(text, pos)) |num| {
            return num;
        }

        if (parseIdentifier(text, pos)) |ident| {
            if (depth > 32) return DefError.RecursionLimit;
            const resolved = self.get(ident) orelse return DefError.UnknownDef;
            const nested = try self.evalExpressionWithDepth(resolved, depth + 1);
            return nested;
        }

        return DefError.InvalidExpression;
    }

    fn parseMul(self: *const DefDict, text: []const u8, pos: *usize, depth: u8) DefError!i64 {
        var value = try self.parsePrimary(text, pos, depth);
        while (true) {
            skipSpaces(text, pos);
            if (pos.* >= text.len or text[pos.*] != '*') break;
            pos.* += 1;
            const rhs = try self.parsePrimary(text, pos, depth);
            value *= rhs;
        }
        return value;
    }

    fn parseAddSub(self: *const DefDict, text: []const u8, pos: *usize, depth: u8) DefError!i64 {
        var value = try self.parseMul(text, pos, depth);
        while (true) {
            skipSpaces(text, pos);
            if (pos.* >= text.len) break;
            const op = text[pos.*];
            if (op != '+' and op != '-') break;
            pos.* += 1;
            const rhs = try self.parseMul(text, pos, depth);
            if (op == '+') {
                value += rhs;
            } else {
                value -= rhs;
            }
        }
        return value;
    }

    fn evalExpressionWithDepth(self: *const DefDict, expr: []const u8, depth: u8) DefError!i64 {
        var pos: usize = 0;
        const value = try self.parseAddSub(expr, &pos, depth);
        skipSpaces(expr, &pos);
        if (pos != expr.len) return DefError.InvalidExpression;
        return value;
    }

    fn evalExpression(self: *const DefDict, expr: []const u8, depth: u8) DefError!i64 {
        return self.evalExpressionWithDepth(expr, depth);
    }
};

test "def dict folds arithmetic expressions" {
    var dict = DefDict.init(std.testing.allocator);
    defer dict.deinit();

    try dict.putExpression("A", "1 + 2 * 3");
    try dict.putExpression("B", "(A + 1) * 2");

    try std.testing.expectEqualStrings("7", dict.get("A").?);
    try std.testing.expectEqualStrings("16", dict.get("B").?);
}

test "foldText handles identifiers with underscores" {
    var dict = DefDict.init(std.testing.allocator);
    defer dict.deinit();

    try dict.putExpression("MY_VAL", "123");
    const folded = try dict.foldText(std.testing.allocator, "call(MY_VAL)");
    defer std.testing.allocator.free(folded);
    try std.testing.expectEqualStrings("call(123)", folded);
}

test "def dict rejects duplicate names" {
    var dict = DefDict.init(std.testing.allocator);
    defer dict.deinit();

    try dict.putExpression("X", "8");
    try std.testing.expectError(DefError.DuplicateDef, dict.putExpression("X", "9"));
}

test "def dict accepts hex literals and bit patterns" {
    var dict = DefDict.init(std.testing.allocator);
    defer dict.deinit();

    try dict.putExpression("HEX", "0x10");
    try dict.putExpression("BIT", "0xffffffffffffffff");

    try std.testing.expectEqualStrings("16", dict.get("HEX").?);
    try std.testing.expectEqualStrings("-1", dict.get("BIT").?);
}

test "def dict ignores trailing inline comments in expressions" {
    var dict = DefDict.init(std.testing.allocator);
    defer dict.deinit();

    try dict.putExpression("MAX_ROWS", "10 // row cap");
    try dict.putExpression("TABLE_ROW_BYTES", "8 // bytes per row");
    try dict.putExpression("TOTAL", "MAX_ROWS * TABLE_ROW_BYTES // derived");

    try std.testing.expectEqualStrings("10", dict.get("MAX_ROWS").?);
    try std.testing.expectEqualStrings("8", dict.get("TABLE_ROW_BYTES").?);
    try std.testing.expectEqualStrings("80", dict.get("TOTAL").?);
}
