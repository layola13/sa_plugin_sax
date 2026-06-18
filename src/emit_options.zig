pub const DceMode = enum {
    no,
    std,
    full,

    pub fn parse(text: []const u8) ?DceMode {
        if (std.mem.eql(u8, text, "no")) return .no;
        if (std.mem.eql(u8, text, "std")) return .std;
        if (std.mem.eql(u8, text, "full")) return .full;
        return null;
    }

    pub fn name(self: DceMode) []const u8 {
        return switch (self) {
            .no => "no",
            .std => "std",
            .full => "full",
        };
    }
};

pub const EmitOptions = struct {
    debug: bool = false,
    wasm_compat: bool = false,
    jobs: ?usize = null,
    test_mode: bool = false,
    opt_level: u8 = 0,
    codegen_unit_index: ?usize = null,
    codegen_unit_count: usize = 1,
    function_task_index: ?usize = null,
    dce: DceMode = .std,
    std_root: ?[]const u8 = null,
};

const std = @import("std");

test "dce mode parsing" {
    try std.testing.expectEqual(DceMode.no, DceMode.parse("no").?);
    try std.testing.expectEqual(DceMode.std, DceMode.parse("std").?);
    try std.testing.expectEqual(DceMode.full, DceMode.parse("full").?);
    try std.testing.expect(DceMode.parse("bad") == null);
}
