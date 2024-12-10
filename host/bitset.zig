const std = @import("std");

// Custom bitset that's different from the ones in Std in two ways:
// - Backed by a SegmentedList to avoid re}llocations
// - Automatically grows in size when setting/getting bit out of current bounds.
pub const BitSet = struct {
    masks: std.SegmentedList(usize, 0) = std.SegmentedList(usize, 0){},

    const ShiftInt = std.math.Log2Int(usize);

    pub fn deinit(self: *BitSet, allocator: std.mem.Allocator) void {
        self.masks.deinit(allocator);
    }

    pub fn setValue(
        self: *BitSet,
        allocator: std.mem.Allocator,
        index: usize,
        value: bool,
    ) !void {
        const mask_index = maskIndex(index);
        while (mask_index >= self.masks.count()) {
            try self.masks.append(allocator, 0);
        }
        const mask = self.masks.at(mask_index);
        const bit = maskBit(index);
        const value_bit = bit & std.math.boolMask(usize, value);
        mask.* = (mask.* & ~bit) | value_bit;
    }

    pub fn isSet(self: *const BitSet, index: usize) bool {
        const mask_index = maskIndex(index);
        if (mask_index >= self.masks.count()) return false;
        return 0 != (self.masks.at(mask_index).* & maskBit(index));
    }

    pub fn findFirstSet(self: *const BitSet) ?usize {
        const mask_count = self.masks.count();
        var mask_index: usize = 0;
        while (mask_index < mask_count) {
            const mask = self.masks.at(mask_index).*;
            if (mask == 0) {
                mask_index += 1;
            } else {
                return (@bitSizeOf(usize) * mask_index) + @ctz(mask);
            }
        }
        return null;
    }

    pub fn unsetAll(self: *BitSet) void {
        var masks = self.masks.iterator(0);
        while (masks.next()) |mask| mask.* = 0;
    }

    pub fn iterator(self: *BitSet) Iterator {
        return .{
            .bitset = self,
            .index = 0,
        };
    }

    fn maskBit(index: usize) usize {
        return @as(usize, 1) << @as(ShiftInt, @truncate(index));
    }

    fn maskIndex(index: usize) usize {
        return index >> @bitSizeOf(ShiftInt);
    }

    pub const Iterator = struct {
        bitset: *const BitSet,
        index: usize,

        pub fn next(self: *Iterator) ?usize {
            const bitset = self.bitset;
            while (maskIndex(self.index) < bitset.masks.count()) {
                const result = self.index;
                self.index += 1;
                if (bitset.isSet(result)) return result;
            } else return null;
        }
    };
};

test BitSet {
    const allocator = std.testing.allocator;
    var bitset = BitSet{};
    defer bitset.deinit(allocator);

    try std.testing.expectEqual(null, bitset.findFirstSet());
    try std.testing.expectEqual(false, bitset.isSet(0));
    try std.testing.expectEqual(false, bitset.isSet(100));

    try bitset.setValue(allocator, 100, true);
    try std.testing.expectEqual(100, bitset.findFirstSet());
    try std.testing.expectEqual(false, bitset.isSet(0));
    try std.testing.expectEqual(true, bitset.isSet(100));

    try bitset.setValue(allocator, 100, true);
    try std.testing.expectEqual(100, bitset.findFirstSet());
    try std.testing.expectEqual(false, bitset.isSet(0));
    try std.testing.expectEqual(true, bitset.isSet(100));

    try bitset.setValue(allocator, 50, true);
    try std.testing.expectEqual(50, bitset.findFirstSet());
    try std.testing.expectEqual(false, bitset.isSet(0));
    try std.testing.expectEqual(true, bitset.isSet(100));
    var iterator = bitset.iterator();
    try std.testing.expectEqual(50, iterator.next());
    try std.testing.expectEqual(100, iterator.next());
    try std.testing.expectEqual(null, iterator.next());

    try bitset.setValue(allocator, 100, false);
    try std.testing.expectEqual(50, bitset.findFirstSet());
    try std.testing.expectEqual(false, bitset.isSet(0));
    try std.testing.expectEqual(false, bitset.isSet(100));

    bitset.unsetAll();
    try std.testing.expectEqual(null, bitset.findFirstSet());
    try std.testing.expectEqual(false, bitset.isSet(50));
}
