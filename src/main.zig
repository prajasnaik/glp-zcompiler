const std = @import("std");
const parser_module = @import("parser.zig");
const programParse = parser_module.programParse;
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

    var file_buf: [4096]u8 = undefined;
    var file_writer = file.writer(&file_buf);
    const writer = &file_writer.interface;

    // Test: arithmetic, booleans (!false, and), comparison, if-else, final expression
    // Expected output: x + y = 10 + 4 = 14
    // Trace: z = (10 > 4) and !false = true and true = true
    //        if (true) -> a = 10 * 2 = 20  [inner, not printed]
    //        final result: x + y = 14
    const input =
        \\x = 10
        \\y = 4
        \\z = x > y and !false
        \\if (z) {
        \\    a = x * 2
        \\} else {
        \\    a = y + 1
        \\}
        \\x + y
    ;

    std.debug.print("\n===== GLP ZCompiler Debug =====\n", .{});
    std.debug.print("[main] Output path: {s}\n", .{output_path});
    std.debug.print("[main] Input program ({d} bytes):\n---\n{s}\n---\n", .{ input.len, input });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    std.debug.print("[main] Starting parser...\n", .{});

    var ast = try programParse(input, allocator);

    defer ast.deinit();

    // 3. Access the root node using `ast.root`, and get its type using `.data`
    std.debug.print("[main] Parsing succeeded. Root node type: {s}\n", .{@tagName(ast.root.data)});

    switch (ast.root.data) {
        .block => |b| {
            std.debug.print("[main] Program has {d} top-level statement(s)\n", .{b.statements.len});
        },
        else => {
            std.debug.print("[main] WARNING: Root node is not a block!\n", .{});
        },
    }

    // Generate assembly
    std.debug.print("[main] Initializing assembly generator...\n", .{});
    var generator = try AsmGenerator.init(writer, arena_allocator);
    defer generator.deinit();

    std.debug.print("[main] Generating assembly...\n", .{});
    try generator.generate(ast.root);

    std.debug.print("[main] Flushing buffered writer...\n", .{});
    // With the new 0.15.1 Writer interface, flush() is a method on the writer directly.
    writer.flush() catch |err| {
        std.debug.print("[main] ERROR: flush failed: {}\n", .{err});
        return err;
    };

    std.debug.print("[main] Assembly generation complete.\n", .{});
    std.debug.print("[main] Assembly written to {s}\n", .{output_path});
    std.debug.print("===== Done =====\n\n", .{});
}
