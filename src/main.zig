const std = @import("std");
const Parser = @import("parser.zig").Parser;
const arithmeticParse = @import("parser.zig").arithmeticParse;
const AsmGenerator = @import("asm_generator.zig").AsmGenerator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <output_file>\n", .{args[0]});
        return;
    }

    const output_path = args[1];

    // Open output file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    var stdout_buf: [1024]u8 = undefined;
    var file_writer = file.writer(&stdout_buf);
    const writer = &file_writer.interface;

    const input = "2^3^2 + 5* (4 - 2)"; // Example input expression

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const root = arithmeticParse(input, arena_allocator) catch |err| {
        std.debug.print("\nParsing failed with error: {}\n", .{err});
        return err;
    };

    // Generate assembly with header, body, and footer
    var generator = try AsmGenerator.init(writer);
    try generator.generate(root);

    std.debug.print("Assembly written to {s}\n", .{output_path});
}
