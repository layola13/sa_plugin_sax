const std = @import("std");

pub const CapabilityMask = enum(u16) {
    uninitialized = 0x00,
    active = 0x01,
    locked_read = 0x02,
    locked_mut = 0x04,
    consumed = 0x08,
    borrow_view = 0x10,
    ffi_borrow = 0x20,
    untracked = 0x40,
    fallible = 0x80,
    immutable = 0x0100,
    interior_ptr = 0x0200,
};

pub const Transition = struct {
    prev_mask: u16,
    op: Op,
    legal: bool,
    new_mask: u16,
    trap: ?TrapKind,
};

pub fn maskName(mask: u16) []const u8 {
    return switch (mask) {
        0x00 => "Uninitialized",
        0x01 => "Active",
        0x02 => "Locked_Read",
        0x04 => "Locked_Mut",
        0x08 => "Consumed",
        0x10 => "BorrowView",
        0x20 => "FfiBorrow",
        0x40 => "Untracked",
        0x80 => "Fallible",
        0x0100 => "Immutable",
        0x0200 => "InteriorPtr",
        else => "Composite",
    };
}

pub const Op = enum(u8) {
    alloc,
    borrow_read,
    borrow_mut,
    borrow_read_again,
    move_,
    release_borrow,
    release_own,
    ffi_raw_cast,
    ffi_assume_safe,
    ffi_assume_borrow,
};

pub const TrapKind = enum(u8) {
    read_write_conflict,
    borrow_conflict,
    double_mutable_borrow,
    use_after_move,
    memory_leak,
    illegal_unsafe_context,
    ffi_ownership_violation,
    stack_escape,
};

pub const TRUTH_TABLE = [_]Transition{
    .{ .prev_mask = 0x00, .op = .alloc, .legal = true, .new_mask = 0x01, .trap = null },
    .{ .prev_mask = 0x01, .op = .borrow_read, .legal = true, .new_mask = 0x02, .trap = null },
    .{ .prev_mask = 0x01, .op = .borrow_mut, .legal = true, .new_mask = 0x04, .trap = null },
    .{ .prev_mask = 0x02, .op = .borrow_read_again, .legal = true, .new_mask = 0x02, .trap = null },
    .{ .prev_mask = 0x02, .op = .borrow_mut, .legal = false, .new_mask = 0x00, .trap = .read_write_conflict },
    .{ .prev_mask = 0x04, .op = .borrow_read, .legal = false, .new_mask = 0x00, .trap = .borrow_conflict },
    .{ .prev_mask = 0x04, .op = .borrow_mut, .legal = false, .new_mask = 0x00, .trap = .double_mutable_borrow },
    .{ .prev_mask = 0x04, .op = .move_, .legal = false, .new_mask = 0x00, .trap = .borrow_conflict },
    .{ .prev_mask = 0x01, .op = .move_, .legal = true, .new_mask = 0x08, .trap = null },
    .{ .prev_mask = 0x08, .op = .alloc, .legal = false, .new_mask = 0x00, .trap = .use_after_move },
    .{ .prev_mask = 0x11, .op = .release_borrow, .legal = true, .new_mask = 0x01, .trap = null },
    .{ .prev_mask = 0x01, .op = .release_own, .legal = true, .new_mask = 0x08, .trap = null },
    .{ .prev_mask = 0x40, .op = .ffi_raw_cast, .legal = true, .new_mask = 0x40, .trap = null },
    .{ .prev_mask = 0x40, .op = .ffi_assume_safe, .legal = true, .new_mask = 0x01, .trap = null },
    .{ .prev_mask = 0x40, .op = .ffi_assume_borrow, .legal = true, .new_mask = 0x33, .trap = null },
    .{ .prev_mask = 0x100, .op = .alloc, .legal = true, .new_mask = 0x100, .trap = null },
    .{ .prev_mask = 0x200, .op = .move_, .legal = true, .new_mask = 0x200, .trap = null },
};

test "truth table contains canonical transitions" {
    try std.testing.expectEqual(@as(usize, 17), TRUTH_TABLE.len);
    try std.testing.expect(TRUTH_TABLE[0].legal);
    try std.testing.expectEqual(@as(u16, 0x01), TRUTH_TABLE[0].new_mask);
    try std.testing.expectEqual(@as(?TrapKind, .read_write_conflict), TRUTH_TABLE[4].trap);
}

test "mask names cover canonical states" {
    try std.testing.expectEqualStrings("Active", maskName(0x01));
    try std.testing.expectEqualStrings("BorrowView", maskName(0x10));
    try std.testing.expectEqualStrings("FfiBorrow", maskName(0x20));
    try std.testing.expectEqualStrings("Fallible", maskName(0x80));
    try std.testing.expectEqualStrings("Immutable", maskName(0x0100));
    try std.testing.expectEqualStrings("InteriorPtr", maskName(0x0200));
}
