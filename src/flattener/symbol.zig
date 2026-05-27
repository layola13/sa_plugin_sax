const std = @import("std");

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(u32),
    names: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(u32).init(allocator),
            .names = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        for (self.names.items) |entry_name| {
            self.allocator.free(entry_name);
        }
        self.names.deinit();
        self.map.deinit();
    }

    pub fn intern(self: *SymbolTable, raw_name: []const u8) !u32 {
        if (self.map.get(raw_name)) |id| return id;

        const owned = try self.allocator.dupe(u8, raw_name);
        errdefer self.allocator.free(owned);

        const id: u32 = @intCast(self.names.items.len);
        try self.names.append(owned);
        try self.map.put(owned, id);
        return id;
    }

    pub fn findId(self: *const SymbolTable, raw_name: []const u8) ?u32 {
        return self.map.get(raw_name);
    }

    pub fn contains(self: *const SymbolTable, raw_name: []const u8) bool {
        return self.map.contains(raw_name);
    }

    pub fn lookupName(self: *const SymbolTable, id: u32) ?[]const u8 {
        const index: usize = @intCast(id);
        if (index >= self.names.items.len) return null;
        return self.names.items[index];
    }
};

test "symbol table interns stable ids" {
    var table = SymbolTable.init(std.testing.allocator);
    defer table.deinit();

    const a = try table.intern("node");
    const b = try table.intern("node");
    const c = try table.intern("view");

    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(u32, 1), c);
    try std.testing.expectEqualStrings("node", table.lookupName(a).?);
}
