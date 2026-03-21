const std = @import("std");
const parser_module = @import("parser.zig");
const programParse = parser_module.programParse;
const AsmGenerator = @import("asm_generator.zig").AsmGenerator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // ── Argument parsing ──────────────────────────────────────
    // Expected form:  glp-zcompiler <input.dpl> -o <output.s>
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("error: -o requires an argument\n", .{});
                std.debug.print("Usage: {s} <input.dpl> -o <output.s>\n", .{args[0]});
                return error.MissingOutputPath;
            }
            output_path = args[i];
        } else {
            if (input_path != null) {
                std.debug.print("error: unexpected argument '{s}'\n", .{args[i]});
                std.debug.print("Usage: {s} <input.dpl> -o <output.s>\n", .{args[0]});
                return error.UnexpectedArgument;
            }
            input_path = args[i];
        }
    }

    if (input_path == null or output_path == null) {
        std.debug.print("Usage: {s} <input.dpl> -o <output.s>\n", .{args[0]});
        return error.MissingArguments;
    }

    const in_path = input_path.?;
    const out_path = output_path.?;

    // ── Validate output directory exists ─────────────────────
    if (std.fs.path.dirname(out_path)) |dir| {
        if (dir.len > 0) {
            std.fs.cwd().access(dir, .{}) catch {
                std.debug.print("error: output directory '{s}' does not exist\n", .{dir});
                return error.OutputDirectoryNotFound;
            };
        }
    }

    // ── Read input file ───────────────────────────────────────
    const input_file = std.fs.cwd().openFile(in_path, .{}) catch |err| {
        std.debug.print("error: could not open input file '{s}': {s}\n", .{ in_path, @errorName(err) });
        return err;
    };
    defer input_file.close();

    const input = input_file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch |err| {
        std.debug.print("error: could not read input file '{s}': {s}\n", .{ in_path, @errorName(err) });
        return err;
    };
    defer allocator.free(input);

    // ── Open output file ──────────────────────────────────────
    const out_file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
        std.debug.print("error: could not create output file '{s}': {s}\n", .{ out_path, @errorName(err) });
        return err;
    };
    defer out_file.close();

    var file_buf: [4096]u8 = undefined;
    var file_writer = out_file.writer(&file_buf);
    const writer = &file_writer.interface;

    // ── Open map file ─────────────────────────────────────────
    const map_path = if (std.mem.endsWith(u8, out_path, ".s"))
        try std.fmt.allocPrint(allocator, "{s}.map", .{out_path[0 .. out_path.len - 2]})
    else
        try std.fmt.allocPrint(allocator, "{s}.map", .{out_path});
    defer allocator.free(map_path);

    const map_file = try std.fs.cwd().createFile(map_path, .{});
    defer map_file.close();
    var map_buf: [16384]u8 = undefined;
    var map_file_writer = map_file.writer(&map_buf);
    const map_writer = &map_file_writer.interface;

    // ── Compile ───────────────────────────────────────────────
    std.debug.print("\n===== GLP ZCompiler =====\n", .{});
    std.debug.print("[main] Input:  {s}\n", .{in_path});
    std.debug.print("[main] Output: {s}\n", .{out_path});
    std.debug.print("[main] Source ({d} bytes):\n---\n{s}\n---\n", .{ input.len, input });

    std.debug.print("[main] Parsing...\n", .{});
    var ast = try programParse(input, allocator);
    defer ast.deinit();

    std.debug.print("[main] Parsed OK. Root: {s}\n", .{@tagName(ast.root.data)});
    switch (ast.root.data) {
        .block => |b| std.debug.print("[main] {d} top-level statement(s)\n", .{b.statements.len}),
        else => std.debug.print("[main] WARNING: root is not a block\n", .{}),
    }

    std.debug.print("[main] Generating assembly...\n", .{});
    var generator = try AsmGenerator.init(writer, allocator, input, map_writer);
    defer generator.deinit();
    try generator.generate(ast.root);

    writer.flush() catch |err| {
        std.debug.print("[main] ERROR: flush failed: {}\n", .{err});
        return err;
    };
    map_writer.flush() catch |err| {
        std.debug.print("[main] ERROR: map flush failed: {}\n", .{err});
        return err;
    };

    std.debug.print("[main] Done. Assembly written to {s}\n", .{out_path});
    std.debug.print("=========================\n\n", .{});
}
