const std = @import("std");

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace) noreturn {
    _ = stack_trace;
    if (std.mem.eql(u8, message, "attempt to unwrap error: Whatever")) {
        std.process.exit(0);
    }
    std.process.exit(1);
}
pub fn main() !void {
    bar() catch unreachable;
    return error.TestFailed;
}
fn bar() !void {
    return error.Whatever;
}
// run
// backend=stage1
// target=native