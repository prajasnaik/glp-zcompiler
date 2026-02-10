const std = @import("std");

pub fn main() !void {
    const input = "300 + 5 * 40";

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try arithmeticParse(input, allocator);

    // Assembly Header
    // We use .intel_syntax for readability.
    // We use .globl main so GCC can find the entry point.
    std.debug.print(
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

    // Generate the math instructions
    try generateAsm(root);

    // Assembly Footer
    // Result is in RAX. We move it to RSI for printf.
    std.debug.print(
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

pub fn generateAsm(node: *Node) !void {
    if (node.isOperator) {
        // 1. Process left side
        if (node.left) |left| {
            try generateAsm(left);
            std.debug.print("    push rax\n", .{});
        }

        // 2. Process right side
        if (node.right) |right| {
            try generateAsm(right);
        }

        // 3. Move right result to rbx, retrieve left from stack into rax
        std.debug.print("    mov rbx, rax\n", .{});
        std.debug.print("    pop rax\n", .{});

        // 4. Perform math
        switch (node.operator.?) {
            '+' => std.debug.print("    add rax, rbx\n", .{}),
            '-' => std.debug.print("    sub rax, rbx\n", .{}),
            '*' => std.debug.print("    imul rax, rbx\n", .{}),
            '/' => {
                std.debug.print("    cqo\n", .{}); // Sign-extend RAX into RDX for idiv
                std.debug.print("    idiv rbx\n", .{});
            },
            else => unreachable,
        }
    } else {
        // Leaf node: just load the number
        const val = @as(i64, @intFromFloat(node.operand.?));
        std.debug.print("    mov rax, {d}\n", .{val});
    }
}

// --- Minimal Parser ---

const Node = struct {
    isOperator: bool,
    operator: ?u8,
    operand: ?f32,
    left: ?*Node,
    right: ?*Node,
};

const allowedOperators = [_]u8{ '+', '-', '*', '/' };

// Need to add parentheses handling and operator precedence for a complete parser.
pub fn arithmeticParse(str: []const u8, allocator: std.mem.Allocator) !*Node {
    const root = try allocator.create(Node);
    root.* = .{ .isOperator = false, .operator = null, .operand = null, .left = null, .right = null };

    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        const char = str[i];
        if (std.mem.indexOfScalar(u8, &allowedOperators, char) != null) {
            root.isOperator = true;
            root.operator = char;
            root.left = try arithmeticParse(str[0..i], allocator);
            root.right = try arithmeticParse(str[i + 1 ..], allocator);
            return root;
        }
    }

    if (!root.isOperator) {
        const trimmed = std.mem.trim(u8, str, " \t\n\r");
        root.operand = try std.fmt.parseFloat(f32, trimmed);
    }
    return root;
}
