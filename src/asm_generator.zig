const std = @import("std");
const Node = @import("parser.zig").Node;

pub const AsmGenerator = struct {
    writer: *std.Io.Writer, // Keeping your custom interface definition
    allocator: std.mem.Allocator,
    variables: std.StringHashMap(i32),
    stack_offset: i32,

    pub fn init(writer: *std.Io.Writer, allocator: std.mem.Allocator) !AsmGenerator {
        return .{
            .writer = writer,
            .allocator = allocator,
            .variables = std.StringHashMap(i32).init(allocator),
            .stack_offset = 0,
        };
    }

    pub fn deinit(self: *AsmGenerator) void {
        self.variables.deinit();
    }

    pub fn generate(self: *AsmGenerator, root: *Node) !void {
        // Updated to use root.data
        std.debug.print("[asm] generate: starting with root type={s}\n", .{@tagName(root.data)});
        std.debug.print("[asm] generate: writing header...\n", .{});
        try self.printHeader();
        std.debug.print("[asm] generate: writing body...\n", .{});
        try self.generateNode(root);
        std.debug.print("[asm] generate: writing footer...\n", .{});
        try self.printFooter();
        std.debug.print("[asm] generate: done\n", .{});
    }

    fn printHeader(self: *AsmGenerator) !void {
        try self.writer.print(
            \\    .intel_syntax noprefix
            \\    .section .rodata
            \\fmt:
            \\    .string "Result: %ld\n"
            \\
            \\    .section .text
            \\    .globl main
            \\
            \\main:
            \\    push rbp
            \\    mov rbp, rsp
            \\    sub rsp, 256
            \\
        , .{});
    }

    fn printFooter(self: *AsmGenerator) !void {
        try self.writer.print(
            \\    lea rdi, [rip + fmt]    # First arg: format string
            \\    mov rsi, rax            # Second arg: result
            \\    xor eax, eax            # printf expects 0 in EAX for varargs
            \\    call printf@PLT
            \\
            \\    xor eax, eax            # Return 0
            \\    leave
            \\    ret
            \\
        , .{});
    }

    fn generateNode(self: *AsmGenerator, node: *Node) !void {
        std.debug.print("[asm] generateNode: type={s}", .{@tagName(node.data)});

        // Update debug prints to use new field names and node.data
        switch (node.data) {
            .assignment => |a| std.debug.print(" target='{s}'", .{a.target}), // .name -> .target
            .variable => |v| std.debug.print(" name='{s}'", .{v}),
            .literal => |l| {
                switch (l) {
                    .number => |n| std.debug.print(" value={d}", .{n}),
                    else => std.debug.print(" value=unsupported_literal", .{}),
                }
            },
            .binary => |b| std.debug.print(" op='{s}'", .{@tagName(b.op)}), // .binary_op -> .binary, .operator -> .op
            .block => |b| std.debug.print(" stmts={d}", .{b.statements.len}),
            .if_statement => std.debug.print(" (if statement)", .{}),
        }
        std.debug.print("\n", .{});

        // Update logic to use node.data
        switch (node.data) {
            .block => |b| {
                std.debug.print("[asm]   block: processing {d} statement(s)\n", .{b.statements.len});
                for (b.statements, 0..) |stmt, i| {
                    std.debug.print("[asm]   block: statement [{d}]\n", .{i});
                    try self.generateNode(stmt);
                }
            },
            .assignment => |a| {
                std.debug.print("[asm]   assignment: evaluating RHS for '{s}'\n", .{a.target}); // .name -> .target
                try self.generateNode(a.value);
                self.stack_offset += 8;
                try self.variables.put(a.target, self.stack_offset); // .name -> .target
                std.debug.print("[asm]   assignment: '{s}' stored at[rbp - {d}]\n", .{ a.target, self.stack_offset });
                try self.writer.print("    mov [rbp - {d}], rax\n", .{self.stack_offset});
            },
            .variable => |name| {
                const offset = self.variables.get(name).?;
                std.debug.print("[asm]   variable: '{s}' loaded from [rbp - {d}]\n", .{ name, offset });
                try self.writer.print("    mov rax,[rbp - {d}]\n", .{offset});
            },
            .binary => |b| { // .binary_op -> .binary
                try self.generateNode(b.left);
                try self.writer.print("    push rax\n", .{});

                try self.generateNode(b.right);

                try self.writer.print("    mov rbx, rax\n", .{});
                try self.writer.print("    pop rax\n", .{});

                switch (b.op) { // .operator -> .op
                    .plus => try self.writer.print("    add rax, rbx\n", .{}),
                    .minus => try self.writer.print("    sub rax, rbx\n", .{}),
                    .star => try self.writer.print("    imul rax, rbx\n", .{}),
                    .slash => {
                        try self.writer.print("    cqo\n", .{});
                        try self.writer.print("    idiv rbx\n", .{});
                    },
                    .caret => {
                        try self.writer.print("    cvtsi2sd xmm0, rax      # Convert base to double\n", .{});
                        try self.writer.print("    cvtsi2sd xmm1, rbx      # Convert exponent to double\n", .{});
                        try self.writer.print("    call pow@PLT\n", .{});
                        try self.writer.print("    cvttsd2si rax, xmm0     # Convert result back to integer\n", .{});
                    },
                    else => unreachable,
                }
            },
            .literal => |lit| { // .number -> .literal
                switch (lit) {
                    .number => |val| {
                        const int_val = @as(i64, @intFromFloat(val)); // Note: val is f64 now (from new parser)
                        try self.writer.print("    mov rax, {d}\n", .{int_val});
                    },
                    else => {
                        // For when you add booleans/strings, handle them here!
                        std.debug.print("Code Generation for this literal type is not implemented yet.\n", .{});
                        unreachable;
                    },
                }
            },
            .if_statement => {
                std.debug.print("Code generation for if statements is not implemented yet.\n", .{});
            },
        }
    }
};
