const std = @import("std");
const tests = @import("tests.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const writer = &stdout_writer.interface;

    const results = try tests.runTests(allocator, writer);
    try writer.flush();

    // Exit with failure code if any tests failed
    if (results.failed > 0) {
        std.process.exit(1);
    }
}
