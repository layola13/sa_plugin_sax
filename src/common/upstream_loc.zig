const std = @import("std");

pub const UpstreamLoc = struct {
    file: []const u8,
    line: u32,
    col: u32,
};

pub const LocTable = []?UpstreamLoc;

test "upstream loc is a plain data carrier" {
    const loc = UpstreamLoc{
        .file = "main.rs",
        .line = 42,
        .col = 7,
    };

    try std.testing.expectEqualStrings("main.rs", loc.file);
    try std.testing.expectEqual(@as(u32, 42), loc.line);
    try std.testing.expectEqual(@as(u32, 7), loc.col);
}
