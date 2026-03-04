const std = @import("std");
const Node = @import("parser.zig").Node;

pub const AsmGenerator = struct {
    writer: *std.Io.Writer,
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
        std.debug.print("[asm] generate: starting with root type={s}\n", .{@tagName(root.node_type)});
        std.debug.print("[asm] generate: writing header...\n", .{});
        try self.printHeader();
        std.debug.print("[asm] generate: writing body...\n", .{});
        try self.generateNode(root);
        std.debug.print("[asm] generate: writing footer...\n", .{});
        try self.printFooter();
        std.debug.print("[asm] generate: done\n", .{});
    }

    fn printHeader(self: *AsmGenerator) !void {
        // Assembly Header
        // We use .intel_syntax for readability.
        // We use .globl main so GCC can find the entry point.
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
        // Assembly Footer
        // Result is in RAX. We move it to RSI for printf.
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
        std.debug.print("[asm] generateNode: type={s}", .{@tagName(node.node_type)});
        switch (node.node_type) {
            .assignment => std.debug.print(" name='{s}'", .{node.name orelse "<null>"}),
            .variable => std.debug.print(" name='{s}'", .{node.name orelse "<null>"}),
            .number => std.debug.print(" value={d}", .{node.operand orelse 0}),
            .binary_op => std.debug.print(" op='{c}'", .{node.operator orelse '?'}),
            .block => std.debug.print(" stmts={d}", .{if (node.statements) |s| s.len else 0}),
        }
        std.debug.print("\n", .{});

        switch (node.node_type) {
            .block => {
                if (node.statements) |stmts| {
                    std.debug.print("[asm]   block: processing {d} statement(s)\n", .{stmts.len});
                    for (stmts, 0..) |stmt, i| {
                        std.debug.print("[asm]   block: statement [{d}]\n", .{i});
                        try self.generateNode(stmt);
                    }
                } else {
                    std.debug.print("[asm]   block: WARNING - no statements!\n", .{});
                }
            },
            .assignment => {
                std.debug.print("[asm]   assignment: evaluating RHS for '{s}'\n", .{node.name orelse "<null>"});
                // Evaluate the right-hand side expression
                try self.generateNode(node.left.?);
                // Allocate stack slot and store result
                self.stack_offset += 8;
                try self.variables.put(node.name.?, self.stack_offset);
                std.debug.print("[asm]   assignment: '{s}' stored at [rbp - {d}]\n", .{ node.name orelse "<null>", self.stack_offset });
                try self.writer.print("    mov [rbp - {d}], rax\n", .{self.stack_offset});
            },
            .variable => {
                const offset = self.variables.get(node.name.?).?;
                std.debug.print("[asm]   variable: '{s}' loaded from [rbp - {d}]\n", .{ node.name orelse "<null>", offset });
                try self.writer.print("    mov rax, [rbp - {d}]\n", .{offset});
            },
            .binary_op => {
                // 1. Process left side
                if (node.left) |left| {
                    try self.generateNode(left);
                    try self.writer.print("    push rax\n", .{});
                }

                // 2. Process right side
                if (node.right) |right| {
                    try self.generateNode(right);
                }

                // 3. Move right result to rbx, retrieve left from stack into rax
                try self.writer.print("    mov rbx, rax\n", .{});
                try self.writer.print("    pop rax\n", .{});

                // 4. Perform math
                switch (node.operator.?) {
                    '+' => try self.writer.print("    add rax, rbx\n", .{}),
                    '-' => try self.writer.print("    sub rax, rbx\n", .{}),
                    '*' => try self.writer.print("    imul rax, rbx\n", .{}),
                    '/' => {
                        try self.writer.print("    cqo\n", .{});
                        try self.writer.print("    idiv rbx\n", .{});
                    },
                    '^' => {
                        try self.writer.print("    cvtsi2sd xmm0, rax      # Convert base to double\n", .{});
                        try self.writer.print("    cvtsi2sd xmm1, rbx      # Convert exponent to double\n", .{});
                        try self.writer.print("    call pow@PLT\n", .{});
                        try self.writer.print("    cvttsd2si rax, xmm0     # Convert result back to integer\n", .{});
                    },
                    else => unreachable,
                }
            },
            .number => {
                const val = @as(i64, @intFromFloat(node.operand.?));
                try self.writer.print("    mov rax, {d}\n", .{val});
            },
        }
    }
};
