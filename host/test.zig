const std = @import("std");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
var pages = std.ArrayList(*anyopaque).init(allocator);
const foo = [_]u8{ 1, 2, 3 };

test "list troubles" {
    try pages.append(@constCast(&foo));
}
