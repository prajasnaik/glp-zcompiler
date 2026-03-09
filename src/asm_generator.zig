const std = @import("std");
const Node = @import("parser.zig").Node;

pub const AsmGenerator = struct {
    writer: *std.Io.Writer, // Keeping your custom interface definition
    allocator: std.mem.Allocator,
    variables: std.StringHashMap(i32),
    stack_offset: i32,
    label_counter: u32,

    pub fn init(writer: *std.Io.Writer, allocator: std.mem.Allocator) !AsmGenerator {
        return .{
            .writer = writer,
            .allocator = allocator,
            .variables = std.StringHashMap(i32).init(allocator),
            .stack_offset = 0,
            .label_counter = 0,
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
            .unary => |u| std.debug.print(" op='{s}'", .{@tagName(u.op)}),
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
                    // Comparison operators
                    .equal_equal => {
                        try self.writer.print("    cmp rax, rbx\n", .{});
                        try self.writer.print("    sete al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    .not_equal => {
                        try self.writer.print("    cmp rax, rbx\n", .{});
                        try self.writer.print("    setne al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    .lt => {
                        try self.writer.print("    cmp rax, rbx\n", .{});
                        try self.writer.print("    setl al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    .gt => {
                        try self.writer.print("    cmp rax, rbx\n", .{});
                        try self.writer.print("    setg al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    .lt_equal => {
                        try self.writer.print("    cmp rax, rbx\n", .{});
                        try self.writer.print("    setle al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    .gt_equal => {
                        try self.writer.print("    cmp rax, rbx\n", .{});
                        try self.writer.print("    setge al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    // Logical operators (bitwise on 0/1 truth values)
                    .kw_and => {
                        // Normalize both to 0/1, then AND
                        try self.writer.print("    test rax, rax\n", .{});
                        try self.writer.print("    setne al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                        try self.writer.print("    test rbx, rbx\n", .{});
                        try self.writer.print("    setne cl\n", .{});
                        try self.writer.print("    and al, cl\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    .kw_or => {
                        // Normalize both to 0/1, then OR
                        try self.writer.print("    test rax, rax\n", .{});
                        try self.writer.print("    setne al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                        try self.writer.print("    test rbx, rbx\n", .{});
                        try self.writer.print("    setne cl\n", .{});
                        try self.writer.print("    or al, cl\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
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
                    .boolean => |val| {
                        const int_val: i64 = if (val) 1 else 0;
                        try self.writer.print("    mov rax, {d}\n", .{int_val});
                    },
                    else => {
                        std.debug.print("Code Generation for this literal type is not implemented yet.\n", .{});
                        unreachable;
                    },
                }
            },
            .unary => |u| {
                try self.generateNode(u.operand);
                switch (u.op) {
                    .bang => {
                        // Logical NOT: if rax == 0 then 1, else 0
                        try self.writer.print("    cmp rax, 0\n", .{});
                        try self.writer.print("    sete al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    else => unreachable,
                }
            },
            .if_statement => |if_stmt| {
                const label_id = self.label_counter;
                self.label_counter += 1;

                // Evaluate the condition — result goes into rax
                try self.generateNode(if_stmt.condition);
                try self.writer.print("    cmp rax, 0\n", .{});

                if (if_stmt.else_branch) |else_branch| {
                    // if-else: jump to else on false, fall through to then
                    try self.writer.print("    je .Lelse_{d}\n", .{label_id});
                    try self.generateNode(if_stmt.then_branch);
                    try self.writer.print("    jmp .Lend_{d}\n", .{label_id});
                    try self.writer.print(".Lelse_{d}:\n", .{label_id});
                    try self.generateNode(else_branch);
                    try self.writer.print(".Lend_{d}:\n", .{label_id});
                } else {
                    // if without else: jump past then-branch on false
                    try self.writer.print("    je .Lend_{d}\n", .{label_id});
                    try self.generateNode(if_stmt.then_branch);
                    try self.writer.print(".Lend_{d}:\n", .{label_id});
                }
            },
        }
    }
};
