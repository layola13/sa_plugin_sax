const std = @import("std");
const cap = @import("../common/capability.zig");

pub const TableError = error{
    UnknownRegister,
    BorrowConflict,
    UseAfterMove,
    DoubleMutableBorrow,
    ReadWriteConflict,
    RegisterRedefinition,
    MemoryLeak,
    IllegalUnsafeContext,
    FfiOwnershipViolation,
};

fn maskOf(tag: cap.CapabilityMask) u16 {
    return @intFromEnum(tag);
}

pub const CapabilityTable = struct {
    allocator: std.mem.Allocator,
    masks: []u16,
    origins: []?u32,
    lock_refs: []u16,
    flags: []u8,

    pub fn init(allocator: std.mem.Allocator, count: usize) !CapabilityTable {
        const table = CapabilityTable{
            .allocator = allocator,
            .masks = try allocator.alloc(u16, count),
            .origins = try allocator.alloc(?u32, count),
            .lock_refs = try allocator.alloc(u16, count),
            .flags = try allocator.alloc(u8, count),
        };
        @memset(table.masks, 0);
        @memset(table.origins, null);
        @memset(table.lock_refs, 0);
        @memset(table.flags, 0);
        return table;
    }

    pub fn deinit(self: *CapabilityTable) void {
        self.allocator.free(self.masks);
        self.allocator.free(self.origins);
        self.allocator.free(self.lock_refs);
        self.allocator.free(self.flags);
    }

    pub fn reset(self: *CapabilityTable) void {
        @memset(self.masks, 0);
        @memset(self.origins, null);
        @memset(self.lock_refs, 0);
        @memset(self.flags, 0);
    }

    fn ensureIndex(self: *CapabilityTable, id: u32) TableError!usize {
        const index: usize = @intCast(id);
        if (index >= self.masks.len) return TableError.UnknownRegister;
        return index;
    }

    fn currentMask(self: *CapabilityTable, id: u32) TableError!u16 {
        const index = try self.ensureIndex(id);
        return self.masks[index];
    }

    pub fn snapshotMasks(self: *CapabilityTable, allocator: std.mem.Allocator) ![]u16 {
        return try allocator.dupe(u16, self.masks);
    }

    pub fn bindActive(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        self.masks[index] = maskOf(.active);
        self.origins[index] = null;
        self.lock_refs[index] = 0;
        self.flags[index] = 0;
    }

    pub fn bindRaw(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        self.masks[index] = maskOf(.untracked);
        self.origins[index] = null;
        self.lock_refs[index] = 0;
        self.flags[index] = 0;
    }

    pub fn noteAlloc(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        const current = self.masks[index];
        if (current != 0 and current != maskOf(.consumed) and current != maskOf(.untracked)) return TableError.RegisterRedefinition;
        self.masks[index] = maskOf(.active);
        self.origins[index] = null;
        self.lock_refs[index] = 0;
        self.flags[index] = 0;
    }

    pub fn noteRead(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        const current = self.masks[index];
        if ((current & maskOf(.untracked)) != 0) return;
        switch (current) {
            0x00 => return TableError.UnknownRegister,
            0x08 => return TableError.UseAfterMove,
            0x04 => return TableError.BorrowConflict,
            else => {},
        }
    }

    pub fn noteWrite(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        const current = self.masks[index];
        if ((current & maskOf(.untracked)) != 0) return;
        switch (current) {
            0x00 => return TableError.UnknownRegister,
            0x08 => return TableError.UseAfterMove,
            0x02 => return TableError.ReadWriteConflict,
            0x04 => return TableError.BorrowConflict,
            else => {},
        }
    }

    pub fn noteBorrowView(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        const current = self.masks[index];
        switch (current) {
            0x00 => return TableError.UnknownRegister,
            0x08 => return TableError.UseAfterMove,
            else => {
                self.masks[index] = current | maskOf(.borrow_view);
            },
        }
    }

    pub fn noteMoveView(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        const current = self.masks[index];
        if ((current & maskOf(.ffi_borrow)) != 0) return TableError.FfiOwnershipViolation;
        switch (current) {
            0x00 => return TableError.UnknownRegister,
            0x08 => return TableError.UseAfterMove,
            0x02, 0x04 => return TableError.BorrowConflict,
            0x40 => return,
            else => self.masks[index] = maskOf(.consumed),
        }
    }

    pub fn noteMove(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        const current = self.masks[index];
        if ((current & maskOf(.ffi_borrow)) != 0) return TableError.FfiOwnershipViolation;
        switch (current) {
            0x00 => return TableError.UnknownRegister,
            0x08 => return TableError.UseAfterMove,
            0x02, 0x04 => return TableError.BorrowConflict,
            0x40 => return,
            else => self.masks[index] = maskOf(.consumed),
        }
    }

    pub fn noteReleaseOwn(self: *CapabilityTable, id: u32) TableError!void {
        const index = try self.ensureIndex(id);
        if ((self.masks[index] & maskOf(.ffi_borrow)) != 0) return TableError.FfiOwnershipViolation;
        switch (self.masks[index]) {
            0x00 => return TableError.UnknownRegister,
            0x08 => return TableError.UseAfterMove,
            0x02, 0x04 => return TableError.BorrowConflict,
            0x40 => return,
            else => self.masks[index] = maskOf(.consumed),
        }
    }

    pub fn startReadBorrow(self: *CapabilityTable, source_id: u32, view_id: u32) TableError!void {
        const source = try self.ensureIndex(source_id);
        const view = try self.ensureIndex(view_id);
        switch (self.masks[source]) {
            0x00 => return TableError.UnknownRegister,
            0x08 => return TableError.UseAfterMove,
            0x04 => return TableError.BorrowConflict,
            0x40 => {
                self.masks[view] = maskOf(.active) | maskOf(.borrow_view) | maskOf(.locked_read) | maskOf(.ffi_borrow);
                self.origins[view] = source_id;
                self.lock_refs[source] += 1;
            },
            else => {
                if (self.masks[source] == 0x01) {
                    self.masks[source] = 0x02;
                }
                self.masks[view] = maskOf(.active) | maskOf(.borrow_view);
                self.origins[view] = source_id;
                self.lock_refs[source] += 1;
            },
        }
    }

    pub fn startMutBorrow(self: *CapabilityTable, source_id: u32, view_id: u32) TableError!void {
        const source = try self.ensureIndex(source_id);
        const view = try self.ensureIndex(view_id);
        switch (self.masks[source]) {
            0x00 => return TableError.UnknownRegister,
            0x08 => return TableError.UseAfterMove,
            0x04 => return TableError.DoubleMutableBorrow,
            0x02 => return TableError.ReadWriteConflict,
            0x40 => {
                self.masks[view] = maskOf(.active) | maskOf(.borrow_view) | maskOf(.locked_mut) | maskOf(.ffi_borrow);
                self.origins[view] = source_id;
                self.lock_refs[source] += 1;
            },
            else => {
                self.masks[source] = 0x04;
                self.masks[view] = maskOf(.active) | maskOf(.borrow_view);
                self.origins[view] = source_id;
                self.lock_refs[source] += 1;
            },
        }
    }

    pub fn releaseBorrow(self: *CapabilityTable, view_id: u32) TableError!void {
        const view = try self.ensureIndex(view_id);
        const origin_id = self.origins[view] orelse return TableError.UnknownRegister;
        const origin = try self.ensureIndex(origin_id);

        if ((self.masks[view] & maskOf(.borrow_view)) == 0) return TableError.UnknownRegister;
        if (self.lock_refs[origin] == 0) return TableError.UnknownRegister;

        self.lock_refs[origin] -= 1;
        if (self.lock_refs[origin] == 0) {
            self.masks[origin] = maskOf(.active);
        }

        self.masks[view] = 0;
        self.origins[view] = null;
        self.flags[view] = 0;
    }

    pub fn finalizeLeaks(self: *CapabilityTable) TableError!void {
        for (self.masks) |mask| {
            if (mask == 0) continue;
            if (mask == maskOf(.consumed)) continue;
            if (mask == maskOf(.untracked)) continue;
            return TableError.MemoryLeak;
        }
    }

    pub fn firstLiveRegister(self: *CapabilityTable) ?u32 {
        for (self.masks, 0..) |mask, idx| {
            if (mask == 0) continue;
            if (mask == maskOf(.consumed)) continue;
            return @intCast(idx);
        }
        return null;
    }
};

test "capability table tracks alloc, move, and borrow transitions" {
    var table = try CapabilityTable.init(std.testing.allocator, 4);
    defer table.deinit();

    try table.noteAlloc(0);
    try std.testing.expectEqual(@as(u16, 0x01), table.masks[0]);
    try table.noteMove(0);
    try std.testing.expectEqual(@as(u16, 0x08), table.masks[0]);

    try table.noteAlloc(1);
    try table.startReadBorrow(1, 2);
    try std.testing.expectEqual(@as(u16, 0x02), table.masks[1]);
    try std.testing.expectEqual(@as(u16, 0x11), table.masks[2]);
    try table.releaseBorrow(2);
    try std.testing.expectEqual(@as(u16, 0x01), table.masks[1]);
}

test "capability table rejects a second exclusive borrow on the same source" {
    var table = try CapabilityTable.init(std.testing.allocator, 4);
    defer table.deinit();

    try table.noteAlloc(0);
    try table.startMutBorrow(0, 1);
    try std.testing.expectEqual(@as(u16, 0x04), table.masks[0]);
    try std.testing.expectEqual(@as(u16, 0x11), table.masks[1]);
    try std.testing.expectError(TableError.DoubleMutableBorrow, table.startMutBorrow(0, 2));
}

test "capability table marks ffi borrow views and blocks consumption" {
    var table = try CapabilityTable.init(std.testing.allocator, 3);
    defer table.deinit();

    try table.bindRaw(0);
    try table.startReadBorrow(0, 1);
    try std.testing.expectEqual(@as(u16, 0x33), table.masks[1]);
    try std.testing.expectError(TableError.FfiOwnershipViolation, table.noteMove(1));
    try std.testing.expectError(TableError.FfiOwnershipViolation, table.noteReleaseOwn(1));
    try table.releaseBorrow(1);
    try std.testing.expectEqual(@as(u16, 0), table.masks[1]);
}
