const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "oh no")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}
pub fn main() !void {
    if (true) @panic("oh no");
    return error.TestFailed;
}
// run
// backend=stage1
// target=native