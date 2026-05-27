const std = @import("std");

pub const Steps = union(enum) {
    bounded: u64,
    unbounded: Unbounded,

    pub const Unbounded = struct {
        bounded_prefix: u64,
    };
};

pub const GasReport = struct {
    max_alloc_bytes: u64,
    max_instruction_steps: Steps,
    call_depth: u16,
    has_unbounded_loop: bool,
};

test "gas report shapes are explicit" {
    const report = GasReport{
        .max_alloc_bytes = 128,
        .max_instruction_steps = .{ .bounded = 42 },
        .call_depth = 2,
        .has_unbounded_loop = false,
    };
    try std.testing.expectEqual(@as(u64, 128), report.max_alloc_bytes);
    try std.testing.expectEqual(@as(u16, 2), report.call_depth);
    try std.testing.expect(!report.has_unbounded_loop);
}
