const std = @import("std");
const Node = @import("parser.zig").Node;

pub const AsmGenerator = struct {
    writer: *std.Io.Writer,

    pub fn init(writer: *std.Io.Writer) !AsmGenerator {
        return .{
            .writer = writer,
        };
    }

    pub fn generate(self: *AsmGenerator, root: *Node) !void {
        try self.printHeader();
        try self.generateExpression(root);
        try self.printFooter();
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
            \\    mov eax, 0              # Return 0
            \\    pop rbp
            \\    ret
            \\
        , .{});
    }

    fn generateExpression(self: *AsmGenerator, node: *Node) !void {
        if (node.isOperator) {
            // 1. Process left side
            if (node.left) |left| {
                try self.generateExpression(left);
                try self.writer.print("    push rax\n", .{});
            }

            // 2. Process right side
            if (node.right) |right| {
                try self.generateExpression(right);
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
                    try self.writer.print("    cqo\n", .{}); // Sign-extend RAX into RDX for idiv
                    try self.writer.print("    idiv rbx\n", .{});
                },
                '^' => {
                    // Exponentiation: rax^rbx -> result in rax using pow() function
                    // Convert base (rax) to XMM0 for pow() call
                    try self.writer.print("    cvtsi2sd xmm0, rax      # Convert base to double\n", .{});
                    // Convert exponent (rbx) to XMM1 for pow() call
                    try self.writer.print("    cvtsi2sd xmm1, rbx      # Convert exponent to double\n", .{});
                    // Call pow function
                    try self.writer.print("    call pow@PLT\n", .{});
                    // Result is in xmm0, convert back to integer
                    try self.writer.print("    cvttsd2si rax, xmm0     # Convert result back to integer\n", .{});
                },
                else => unreachable,
            }
        } else {
            // Leaf node: just load the number
            const val = @as(i64, @intFromFloat(node.operand.?));
            try self.writer.print("    mov rax, {d}\n", .{val});
        }
    }
};
