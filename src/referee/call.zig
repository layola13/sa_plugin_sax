const std = @import("std");
const common_instruction = @import("../common/instruction.zig");
const common_signature = @import("../common/signature.zig");

pub const CallError = error{
    InvalidCallSyntax,
    UnknownFunction,
    CapabilityMismatch,
    OutOfMemory,
};

pub const ParsedArg = struct {
    prefix: common_instruction.CapPrefix,
    text: []const u8,
};

pub const ParsedCall = struct {
    dest: ?[]const u8,
    callee: []const u8,
    args: []ParsedArg,
    is_indirect: bool,

    pub fn deinit(self: *ParsedCall, allocator: std.mem.Allocator) void {
        if (self.dest) |dest| allocator.free(dest);
        allocator.free(self.callee);
        for (self.args) |arg| {
            allocator.free(arg.text);
        }
        allocator.free(self.args);
        self.* = undefined;
    }
};

fn parseArg(allocator: std.mem.Allocator, text: []const u8) !ParsedArg {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return CallError.InvalidCallSyntax;

    return switch (trimmed[0]) {
        '&' => .{
            .prefix = .borrow,
            .text = try allocator.dupe(u8, std.mem.trim(u8, trimmed[1..], " \t")),
        },
        '^' => .{
            .prefix = .move,
            .text = try allocator.dupe(u8, std.mem.trim(u8, trimmed[1..], " \t")),
        },
        '*' => .{
            .prefix = .raw,
            .text = try allocator.dupe(u8, std.mem.trim(u8, trimmed[1..], " \t")),
        },
        else => .{
            .prefix = .by_value,
            .text = try allocator.dupe(u8, trimmed),
        },
    };
}

fn splitCallArgs(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return try allocator.alloc([]const u8, 0);

    var segments = std.ArrayList([]const u8).init(allocator);
    errdefer segments.deinit();

    var paren_depth: usize = 0;
    var brace_depth: usize = 0;
    var bracket_depth: usize = 0;
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
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth == 0) return CallError.InvalidCallSyntax;
                paren_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth == 0) return CallError.InvalidCallSyntax;
                brace_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth == 0) return CallError.InvalidCallSyntax;
                bracket_depth -= 1;
            },
            ',' => {
                if (paren_depth == 0 and brace_depth == 0 and bracket_depth == 0) {
                    const segment = std.mem.trim(u8, trimmed[start..idx], " \t");
                    if (segment.len == 0) return CallError.InvalidCallSyntax;
                    try segments.append(segment);
                    start = idx + 1;
                }
            },
            else => {},
        }
    }

    if (in_string or escape or paren_depth != 0 or brace_depth != 0 or bracket_depth != 0) {
        return CallError.InvalidCallSyntax;
    }

    const final_segment = std.mem.trim(u8, trimmed[start..], " \t");
    if (final_segment.len == 0) return CallError.InvalidCallSyntax;
    try segments.append(final_segment);
    return try segments.toOwnedSlice();
}

fn parseCallBody(allocator: std.mem.Allocator, body: []const u8, is_indirect: bool) !ParsedCall {
    const trimmed = std.mem.trim(u8, body, " \t");
    if (trimmed.len == 0) return CallError.InvalidCallSyntax;

    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return CallError.InvalidCallSyntax;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return CallError.InvalidCallSyntax;
    if (close < open) return CallError.InvalidCallSyntax;
    if (std.mem.trim(u8, trimmed[close + 1 ..], " \t").len != 0) return CallError.InvalidCallSyntax;

    const callee_text = std.mem.trim(u8, trimmed[0..open], " \t");
    if (callee_text.len == 0) return CallError.InvalidCallSyntax;
    const callee_name = if (callee_text[0] == '@') callee_text[1..] else callee_text;

    var args_list = std.ArrayList(ParsedArg).init(allocator);
    errdefer {
        for (args_list.items) |arg| allocator.free(arg.text);
        args_list.deinit();
    }

    const args_text = std.mem.trim(u8, trimmed[open + 1 .. close], " \t");
    if (args_text.len != 0) {
        const fragments = try splitCallArgs(allocator, args_text);
        defer allocator.free(fragments);
        for (fragments) |fragment| {
            try args_list.append(try parseArg(allocator, fragment));
        }
    }

    return .{
        .dest = null,
        .callee = try allocator.dupe(u8, callee_name),
        .args = try args_list.toOwnedSlice(),
        .is_indirect = is_indirect,
    };
}

fn parseSpecialCallBody(allocator: std.mem.Allocator, body: []const u8, callee_name: []const u8) !ParsedCall {
    const trimmed = std.mem.trim(u8, body, " \t");
    if (trimmed.len == 0) return CallError.InvalidCallSyntax;

    const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return CallError.InvalidCallSyntax;
    const close = std.mem.lastIndexOfScalar(u8, trimmed, ')') orelse return CallError.InvalidCallSyntax;
    if (close < open) return CallError.InvalidCallSyntax;
    if (std.mem.trim(u8, trimmed[close + 1 ..], " \t").len != 0) return CallError.InvalidCallSyntax;

    const prefix = std.mem.trim(u8, trimmed[0..open], " \t");
    if (!std.mem.eql(u8, prefix, callee_name)) return CallError.InvalidCallSyntax;

    var args_list = std.ArrayList(ParsedArg).init(allocator);
    errdefer {
        for (args_list.items) |arg| allocator.free(arg.text);
        args_list.deinit();
    }

    const args_text = std.mem.trim(u8, trimmed[open + 1 .. close], " \t");
    if (args_text.len != 0) {
        const fragments = try splitCallArgs(allocator, args_text);
        defer allocator.free(fragments);
        for (fragments) |fragment| {
            try args_list.append(try parseArg(allocator, fragment));
        }
    }

    return .{
        .dest = null,
        .callee = try allocator.dupe(u8, callee_name),
        .args = try args_list.toOwnedSlice(),
        .is_indirect = false,
    };
}

fn startsWithWord(s: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, s, word)) return false;
    if (s.len == word.len) return true;
    const next = s[word.len];
    return std.ascii.isWhitespace(next) or next == '(' or next == '[' or next == ':' or next == '=' or next == '@' or next == '-';
}

pub fn parseCall(allocator: std.mem.Allocator, raw_text: []const u8) !ParsedCall {
    const trimmed = std.mem.trim(u8, raw_text, " \t\r");
    if (trimmed.len == 0) return CallError.InvalidCallSyntax;

    if (startsWithWord(trimmed, "panic_msg")) {
        return parseSpecialCallBody(allocator, trimmed, "panic_msg");
    }
    if (startsWithWord(trimmed, "panic")) {
        return parseSpecialCallBody(allocator, trimmed, "panic");
    }

    const call_start = if (std.mem.indexOf(u8, trimmed, "call_indirect")) |idx| idx else if (std.mem.indexOf(u8, trimmed, "call")) |idx| idx else return CallError.InvalidCallSyntax;
    const prefix = std.mem.trim(u8, trimmed[0..call_start], " \t");
    const dest = if (prefix.len != 0) blk: {
        const eq = std.mem.indexOfScalar(u8, prefix, '=') orelse return CallError.InvalidCallSyntax;
        const name = std.mem.trim(u8, prefix[0..eq], " \t");
        const tail = std.mem.trim(u8, prefix[eq + 1 ..], " \t");
        if (name.len == 0 or tail.len != 0) return CallError.InvalidCallSyntax;
        break :blk try allocator.dupe(u8, name);
    } else null;
    errdefer if (dest) |value| allocator.free(value);

    if (std.mem.indexOf(u8, trimmed, "call_indirect")) |idx| {
        const body = std.mem.trimLeft(u8, trimmed[idx + "call_indirect".len ..], " \t");
        var call = try parseCallBody(allocator, body, true);
        call.dest = dest;
        return call;
    }

    if (std.mem.indexOf(u8, trimmed, "call")) |idx| {
        const body = std.mem.trimLeft(u8, trimmed[idx + "call".len ..], " \t");
        var call = try parseCallBody(allocator, body, false);
        call.dest = dest;
        return call;
    }

    if (dest) |value| allocator.free(value);
    return CallError.InvalidCallSyntax;
}

fn validatePrefix(expected: common_instruction.CapPrefix, actual: common_instruction.CapPrefix) bool {
    return expected == actual;
}

fn prefixText(prefix: common_instruction.CapPrefix) []const u8 {
    return switch (prefix) {
        .by_value => "",
        .borrow => "&",
        .move => "^",
        .raw => "*",
    };
}

pub fn validateCall(
    allocator: std.mem.Allocator,
    sigs: []const common_signature.FunctionSig,
    raw_text: []const u8,
) !ParsedCall {
    var call = try parseCall(allocator, raw_text);
    errdefer call.deinit(allocator);

    if (call.is_indirect) {
        return call;
    }

    if (std.mem.eql(u8, call.callee, "panic")) {
        if (call.args.len != 1 or call.args[0].prefix != .by_value) return CallError.CapabilityMismatch;
        return call;
    }
    if (std.mem.eql(u8, call.callee, "panic_msg")) {
        if (call.args.len != 3 or call.args[0].prefix != .by_value or call.args[1].prefix != .raw or call.args[2].prefix != .by_value) {
            return CallError.CapabilityMismatch;
        }
        return call;
    }

    var sig: ?common_signature.FunctionSig = null;
    for (sigs) |item| {
        if (std.mem.eql(u8, item.name, call.callee)) {
            sig = item;
            break;
        }
    }
    const resolved = sig orelse return CallError.UnknownFunction;
    if (resolved.params.len != call.args.len) return CallError.CapabilityMismatch;

    for (call.args, resolved.params, 0..) |arg, param, idx| {
        if (!validatePrefix(param.cap, arg.prefix)) {
            _ = idx;
            return CallError.CapabilityMismatch;
        }
    }

    return call;
}

test "parse and validate a direct call signature" {
    var sigs = std.ArrayList(common_signature.FunctionSig).init(std.testing.allocator);
    defer {
        for (sigs.items) |*sig| sig.deinit(std.testing.allocator);
        sigs.deinit();
    }

    try sigs.append(try common_signature.parseFunctionSig(std.testing.allocator, "@consume(^p: i32) -> void:", 0, 0));

    var call = try validateCall(std.testing.allocator, sigs.items, "call @consume(^p)");
    defer call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("consume", call.callee);
    try std.testing.expectEqual(@as(usize, 1), call.args.len);
    try std.testing.expectEqual(common_instruction.CapPrefix.move, call.args[0].prefix);
}

test "parse and validate panic builtins" {
    var panic_call = try validateCall(std.testing.allocator, &.{}, "panic(7)");
    defer panic_call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("panic", panic_call.callee);
    try std.testing.expectEqual(@as(usize, 1), panic_call.args.len);
    try std.testing.expectEqual(common_instruction.CapPrefix.by_value, panic_call.args[0].prefix);

    var msg_call = try validateCall(std.testing.allocator, &.{}, "panic_msg(7, *msg, len)");
    defer msg_call.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("panic_msg", msg_call.callee);
    try std.testing.expectEqual(@as(usize, 3), msg_call.args.len);
    try std.testing.expectEqual(common_instruction.CapPrefix.by_value, msg_call.args[0].prefix);
    try std.testing.expectEqual(common_instruction.CapPrefix.raw, msg_call.args[1].prefix);
    try std.testing.expectEqual(common_instruction.CapPrefix.by_value, msg_call.args[2].prefix);
}

test "parseCall rejects trailing garbage on special calls" {
    try std.testing.expectError(CallError.InvalidCallSyntax, parseCall(std.testing.allocator, "panic(7) extra"));
    try std.testing.expectError(CallError.InvalidCallSyntax, parseCall(std.testing.allocator, "panic_msg(7, *msg, len) trailing"));
}

test "parseCall keeps quoted commas inside arguments" {
    var call = try parseCall(std.testing.allocator, "call @sink(utf8:\"a,b\", *\"c,d\", len)");
    defer call.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("sink", call.callee);
    try std.testing.expectEqual(@as(usize, 3), call.args.len);
    try std.testing.expectEqual(common_instruction.CapPrefix.by_value, call.args[0].prefix);
    try std.testing.expectEqualStrings("utf8:\"a,b\"", call.args[0].text);
    try std.testing.expectEqual(common_instruction.CapPrefix.raw, call.args[1].prefix);
    try std.testing.expectEqualStrings("\"c,d\"", call.args[1].text);
    try std.testing.expectEqual(common_instruction.CapPrefix.by_value, call.args[2].prefix);
    try std.testing.expectEqualStrings("len", call.args[2].text);
}

test "validateCall rejects capability mismatches" {
    var sigs = std.ArrayList(common_signature.FunctionSig).init(std.testing.allocator);
    defer {
        for (sigs.items) |*sig| sig.deinit(std.testing.allocator);
        sigs.deinit();
    }

    try sigs.append(try common_signature.parseFunctionSig(std.testing.allocator, "@sink(&p: ptr, ^q: ptr) -> i32:", 0, 0));
    try std.testing.expectError(CallError.CapabilityMismatch, validateCall(std.testing.allocator, sigs.items, "call @sink(^p, ^q)"));
    try std.testing.expectError(CallError.CapabilityMismatch, validateCall(std.testing.allocator, sigs.items, "call @sink(&p)"));
}

test "call contract PBT matches random capability signatures" {
    var prng = std.Random.DefaultPrng.init(0x5A5A_6120);
    const random = prng.random();
    const caps = [_]common_instruction.CapPrefix{ .by_value, .borrow, .move, .raw };

    for (0..96) |iter| {
        const param_count = random.intRangeAtMost(usize, 1, 3);
        var sig_text = std.ArrayList(u8).init(std.testing.allocator);
        defer sig_text.deinit();
        var call_text = std.ArrayList(u8).init(std.testing.allocator);
        defer call_text.deinit();

        try sig_text.writer().writeAll("@sink(");
        try call_text.writer().writeAll("call @sink(");

        var expect_ok = true;
        for (0..param_count) |idx| {
            if (idx != 0) {
                try sig_text.writer().writeAll(", ");
                try call_text.writer().writeAll(", ");
            }

            const param_cap = caps[random.intRangeLessThan(usize, 0, caps.len)];
            const arg_cap = caps[random.intRangeLessThan(usize, 0, caps.len)];
            if (param_cap != arg_cap) expect_ok = false;

            try sig_text.writer().print("{s}p{d}: ptr", .{ prefixText(param_cap), idx });
            try call_text.writer().print("{s}p{d}", .{ prefixText(arg_cap), idx });
        }
        try sig_text.writer().writeAll(") -> i32:");
        try call_text.writer().writeByte(')');

        var sigs = std.ArrayList(common_signature.FunctionSig).init(std.testing.allocator);
        defer {
            for (sigs.items) |*sig| sig.deinit(std.testing.allocator);
            sigs.deinit();
        }
        try sigs.append(try common_signature.parseFunctionSig(std.testing.allocator, sig_text.items, @intCast(iter), 0));

        if (expect_ok) {
            var parsed = try validateCall(std.testing.allocator, sigs.items, call_text.items);
            defer parsed.deinit(std.testing.allocator);
            try std.testing.expectEqual(param_count, parsed.args.len);
        } else {
            try std.testing.expectError(CallError.CapabilityMismatch, validateCall(std.testing.allocator, sigs.items, call_text.items));
        }
    }
}
