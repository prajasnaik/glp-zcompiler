const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;
const DataType = parser.DataType;

/// The active "register" after evaluating a sub-expression.
/// .int  → result is in rax  (integer 64-bit)
/// .float → result is in xmm0 (double-precision)
pub const RegKind = enum { int, float };

/// Tracks where a variable lives on the stack and whether it holds a float or int.
const VarInfo = struct {
    offset: i32,
    kind: RegKind,
};

pub const AsmGenerator = struct {
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    variables: std.StringHashMap(VarInfo),
    prime_slots: std.StringHashMap(VarInfo),
    stack_offset: i32,
    label_counter: u32,
    /// Set to true after generating the last top-level expression so the
    /// footer can choose the correct printf format string.
    result_is_float: bool,

    pub fn init(writer: *std.Io.Writer, allocator: std.mem.Allocator) !AsmGenerator {
        return .{
            .writer = writer,
            .allocator = allocator,
            .variables = std.StringHashMap(VarInfo).init(allocator),
            .prime_slots = std.StringHashMap(VarInfo).init(allocator),
            .stack_offset = 0,
            .label_counter = 0,
            .result_is_float = false,
        };
    }

    pub fn deinit(self: *AsmGenerator) void {
        self.variables.deinit();
        self.prime_slots.deinit();
    }

    pub fn generate(self: *AsmGenerator, root: *Node) !void {
        std.debug.print("[asm] generate: starting with root type={s}\n", .{@tagName(root.data)});
        // First pass: figure out whether the last expression produces a float.
        // We set result_is_float before writing the header so the rodata section
        // can include the right format string.
        if (root.data == .block) {
            const stmts = root.data.block.statements;
            if (stmts.len > 0) {
                const last = stmts[stmts.len - 1];
                self.result_is_float = isFloatNode(last);
            }
        }
        std.debug.print("[asm] generate: writing header (result_is_float={})...\n", .{self.result_is_float});
        try self.printHeader();
        std.debug.print("[asm] generate: writing body...\n", .{});
        try self.generateNode(root);
        std.debug.print("[asm] generate: writing footer...\n", .{});
        try self.printFooter();
        std.debug.print("[asm] generate: done\n", .{});
    }

    fn printHeader(self: *AsmGenerator) !void {
        // Choose the format string based on result type.
        if (self.result_is_float) {
            try self.writer.print(
                \\    .intel_syntax noprefix
                \\    .section .rodata
                \\fmt:
                \\    .string "Result: %f\n"
                \\
                \\    .section .text
                \\    .globl main
                \\
                \\main:
                \\    push rbp
                \\    mov rbp, rsp
                \\    sub rsp, 512
                \\
            , .{});
        } else {
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
                \\    sub rsp, 512
                \\
            , .{});
        }
    }

    fn printFooter(self: *AsmGenerator) !void {
        if (self.result_is_float) {
            // For printf with %f, the double must be passed in xmm0 and eax=1.
            try self.writer.print(
                \\    lea rdi, [rip + fmt]    # First arg: format string
                \\    mov eax, 1              # 1 XMM register used for varargs
                \\    call printf@PLT
                \\
                \\    xor eax, eax            # Return 0
                \\    leave
                \\    ret
                \\
            , .{});
        } else {
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
    }

    /// Returns true when the top-level node will leave its result in xmm0.
    fn isFloatNode(node: *const Node) bool {
        return switch (node.data) {
            .literal => |lit| switch (lit) {
                .float => true,
                else => false,
            },
            .variable => false, // conservative; runtime type known via VarInfo
            .binary => |b| switch (b.op) {
                // Comparison / logical → always int (0/1)
                .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal, .kw_and, .kw_or => false,
                else => isFloatNode(b.left) or isFloatNode(b.right),
            },
            .unary => false,
            .assignment => |a| isFloatNode(a.value),
            .prime_assignment => |pa| isFloatNode(pa.value),
            .block => |bl| blk: {
                if (bl.statements.len == 0) break :blk false;
                break :blk isFloatNode(bl.statements[bl.statements.len - 1]);
            },
            else => false,
        };
    }

    fn generateNode(self: *AsmGenerator, node: *Node) !void {
        std.debug.print("[asm] generateNode: type={s}", .{@tagName(node.data)});

        switch (node.data) {
            .assignment => |a| std.debug.print(" target='{s}'", .{a.target}),
            .variable => |v| std.debug.print(" name='{s}'", .{v}),
            .literal => |l| {
                switch (l) {
                    .int => |n| std.debug.print(" value(int)={d}", .{n}),
                    .float => |n| std.debug.print(" value(float)={d}", .{n}),
                    else => std.debug.print(" value=unsupported_literal", .{}),
                }
            },
            .binary => |b| std.debug.print(" op='{s}'", .{@tagName(b.op)}),
            .block => |b| std.debug.print(" stmts={d}", .{b.statements.len}),
            .unary => |u| std.debug.print(" op='{s}'", .{@tagName(u.op)}),
            .if_statement => std.debug.print(" (if statement)", .{}),
            .while_loop => |wl| std.debug.print(" prime_vars={d}", .{wl.prime_vars.len}),
            .prime_assignment => |pa| std.debug.print(" target='{s}'", .{pa.target}),
        }
        std.debug.print("\n", .{});

        switch (node.data) {
            .block => |b| {
                std.debug.print("[asm]   block: processing {d} statement(s)\n", .{b.statements.len});
                for (b.statements, 0..) |stmt, i| {
                    std.debug.print("[asm]   block: statement [{d}]\n", .{i});
                    try self.generateNode(stmt);
                }
            },
            .assignment => |a| {
                std.debug.print("[asm]   assignment: evaluating RHS for '{s}'\n", .{a.target});
                const kind = try self.generateExpr(a.value);
                self.stack_offset += 8;
                const info = VarInfo{ .offset = self.stack_offset, .kind = kind };
                try self.variables.put(a.target, info);
                std.debug.print("[asm]   assignment: '{s}' stored at [rbp - {d}] ({s})\n", .{ a.target, self.stack_offset, @tagName(kind) });
                switch (kind) {
                    .int => try self.writer.print("    mov [rbp - {d}], rax\n", .{self.stack_offset}),
                    .float => try self.writer.print("    movsd [rbp - {d}], xmm0\n", .{self.stack_offset}),
                }
            },
            .variable => |name| {
                const info = self.variables.get(name).?;
                std.debug.print("[asm]   variable: '{s}' loaded from [rbp - {d}] ({s})\n", .{ name, info.offset, @tagName(info.kind) });
                switch (info.kind) {
                    .int => try self.writer.print("    mov rax, [rbp - {d}]\n", .{info.offset}),
                    .float => try self.writer.print("    movsd xmm0, [rbp - {d}]\n", .{info.offset}),
                }
            },
            // Expressions: delegate to generateExpr (result discarded)
            .binary, .literal, .unary => {
                _ = try self.generateExpr(node);
            },
            .if_statement => |if_stmt| {
                const label_id = self.label_counter;
                self.label_counter += 1;

                // Evaluate the condition — result goes into rax (conditions are always int)
                _ = try self.generateExpr(if_stmt.condition);
                try self.writer.print("    cmp rax, 0\n", .{});

                if (if_stmt.else_branch) |else_branch| {
                    try self.writer.print("    je .Lelse_{d}\n", .{label_id});
                    try self.generateNode(if_stmt.then_branch);
                    try self.writer.print("    jmp .Lend_{d}\n", .{label_id});
                    try self.writer.print(".Lelse_{d}:\n", .{label_id});
                    try self.generateNode(else_branch);
                    try self.writer.print(".Lend_{d}:\n", .{label_id});
                } else {
                    try self.writer.print("    je .Lend_{d}\n", .{label_id});
                    try self.generateNode(if_stmt.then_branch);
                    try self.writer.print(".Lend_{d}:\n", .{label_id});
                }
            },
            .while_loop => |wl| {
                const label_id = self.label_counter;
                self.label_counter += 1;

                // Allocate prime slots.  Infer kind from the corresponding variable.
                for (wl.prime_vars) |name| {
                    self.stack_offset += 8;
                    const orig_info = self.variables.get(name) orelse VarInfo{ .offset = 0, .kind = .int };
                    const slot_info = VarInfo{ .offset = self.stack_offset, .kind = orig_info.kind };
                    try self.prime_slots.put(name, slot_info);
                    std.debug.print("[asm]   while_loop: prime slot for '{s}' at [rbp - {d}] ({s})\n", .{ name, self.stack_offset, @tagName(slot_info.kind) });
                }

                try self.writer.print(".Lloop_start_{d}:\n", .{label_id});

                // Condition — always integer comparison.
                _ = try self.generateExpr(wl.condition);
                try self.writer.print("    cmp rax, 0\n", .{});
                try self.writer.print("    je .Lloop_end_{d}\n", .{label_id});

                try self.generateNode(wl.body);

                // Simultaneous update of old slots from prime (new) slots.
                for (wl.prime_vars) |name| {
                    const old_info = self.variables.get(name).?;
                    const new_info = self.prime_slots.get(name).?;
                    switch (old_info.kind) {
                        .int => {
                            try self.writer.print("    mov rax, [rbp - {d}]\n", .{new_info.offset});
                            try self.writer.print("    mov [rbp - {d}], rax\n", .{old_info.offset});
                        },
                        .float => {
                            try self.writer.print("    movsd xmm0, [rbp - {d}]\n", .{new_info.offset});
                            try self.writer.print("    movsd [rbp - {d}], xmm0\n", .{old_info.offset});
                        },
                    }
                }

                try self.writer.print("    jmp .Lloop_start_{d}\n", .{label_id});
                try self.writer.print(".Lloop_end_{d}:\n", .{label_id});

                for (wl.prime_vars) |name| {
                    _ = self.prime_slots.remove(name);
                }
            },
            .prime_assignment => |pa| {
                std.debug.print("[asm]   prime_assignment: evaluating RHS for '{s}'\n", .{pa.target});
                const kind = try self.generateExpr(pa.value);
                const new_info = self.prime_slots.get(pa.target).?;
                std.debug.print("[asm]   prime_assignment: '{s}' -> [rbp - {d}] ({s})\n", .{ pa.target, new_info.offset, @tagName(kind) });
                switch (kind) {
                    .int => try self.writer.print("    mov [rbp - {d}], rax\n", .{new_info.offset}),
                    .float => try self.writer.print("    movsd [rbp - {d}], xmm0\n", .{new_info.offset}),
                }
            },
        }
    }

    /// Generate code for an expression node.  Returns RegKind indicating
    /// whether the result ended up in rax (.int) or xmm0 (.float).
    fn generateExpr(self: *AsmGenerator, node: *Node) anyerror!RegKind {
        switch (node.data) {
            .literal => |lit| {
                switch (lit) {
                    .int => |val| {
                        try self.writer.print("    mov rax, {d}\n", .{val});
                        return .int;
                    },
                    .float => |val| {
                        // Embed the bit-pattern of the double as a 64-bit immediate via a
                        // temporary integer register, then move to xmm0.
                        const bits: u64 = @bitCast(val);
                        try self.writer.print("    mov rax, {d}    # float bits: {d}\n", .{ bits, val });
                        try self.writer.print("    movq xmm0, rax\n", .{});
                        return .float;
                    },
                    .boolean => |val| {
                        try self.writer.print("    mov rax, {d}\n", .{@as(i64, if (val) 1 else 0)});
                        return .int;
                    },
                    else => {
                        std.debug.print("Code Generation for this literal type is not implemented yet.\n", .{});
                        return error.UnsupportedLiteralType;
                    },
                }
            },
            .variable => |name| {
                const info = self.variables.get(name).?;
                switch (info.kind) {
                    .int => {
                        try self.writer.print("    mov rax, [rbp - {d}]\n", .{info.offset});
                        return .int;
                    },
                    .float => {
                        try self.writer.print("    movsd xmm0, [rbp - {d}]\n", .{info.offset});
                        return .float;
                    },
                }
            },
            .binary => |b| {
                const left_kind = try self.generateExpr(b.left);

                // Push left operand onto stack (always 8 bytes regardless of type).
                switch (left_kind) {
                    .int => try self.writer.print("    push rax\n", .{}),
                    .float => {
                        try self.writer.print("    sub rsp, 8\n", .{});
                        try self.writer.print("    movsd [rsp], xmm0\n", .{});
                    },
                }

                const right_kind = try self.generateExpr(b.right);

                // Promote mixed int/float: if one is float, convert the other.
                const result_kind: RegKind = blk: {
                    switch (b.op) {
                        // Comparisons / logical always produce an int result.
                        .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal, .kw_and, .kw_or => break :blk .int,
                        else => break :blk if (left_kind == .float or right_kind == .float) .float else .int,
                    }
                };

                if (result_kind == .float) {
                    // Pop left into xmm1, ensure right is in xmm0.
                    switch (right_kind) {
                        .int => {
                            // right is in rax → xmm0
                            try self.writer.print("    cvtsi2sd xmm0, rax\n", .{});
                        },
                        .float => {}, // right already in xmm0
                    }
                    // Pop left → xmm1
                    if (left_kind == .int) {
                        // left was pushed as integer
                        try self.writer.print("    pop rax\n", .{});
                        try self.writer.print("    cvtsi2sd xmm1, rax\n", .{});
                    } else {
                        try self.writer.print("    movsd xmm1, [rsp]\n", .{});
                        try self.writer.print("    add rsp, 8\n", .{});
                    }

                    switch (b.op) {
                        .plus => try self.writer.print("    addsd xmm1, xmm0\n", .{}),
                        .minus => try self.writer.print("    subsd xmm1, xmm0\n", .{}),
                        .star => try self.writer.print("    mulsd xmm1, xmm0\n", .{}),
                        .slash => try self.writer.print("    divsd xmm1, xmm0\n", .{}),
                        .caret => {
                            // pow(xmm1, xmm0) — arguments already in xmm0/xmm1 need reordering:
                            // System V ABI: first arg xmm0, second arg xmm1.
                            try self.writer.print("    movapd xmm0, xmm1\n", .{});
                            try self.writer.print("    call pow@PLT\n", .{});
                        },
                        else => unreachable,
                    }
                    // Move result to xmm0 (for non-pow ops result is in xmm1).
                    switch (b.op) {
                        .caret => {}, // result already in xmm0
                        else => try self.writer.print("    movapd xmm0, xmm1\n", .{}),
                    }
                    return .float;
                } else if (result_kind == .int and (b.op == .equal_equal or b.op == .not_equal or
                    b.op == .lt or b.op == .gt or b.op == .lt_equal or b.op == .gt_equal))
                {
                    // Comparison: both operands may be int or float.
                    if (left_kind == .float or right_kind == .float) {
                        // Float comparison path.
                        if (right_kind == .int) {
                            try self.writer.print("    cvtsi2sd xmm1, rax\n", .{});
                        } else {
                            // right is in xmm0 → save to xmm1
                            try self.writer.print("    movapd xmm1, xmm0\n", .{});
                        }
                        if (left_kind == .int) {
                            try self.writer.print("    pop rax\n", .{});
                            try self.writer.print("    cvtsi2sd xmm0, rax\n", .{});
                        } else {
                            try self.writer.print("    movsd xmm0, [rsp]\n", .{});
                            try self.writer.print("    add rsp, 8\n", .{});
                        }
                        // Now: left in xmm0, right in xmm1.
                        try self.writer.print("    ucomisd xmm0, xmm1\n", .{});
                        switch (b.op) {
                            .equal_equal => {
                                try self.writer.print("    sete al\n", .{});
                                try self.writer.print("    movzx rax, al\n", .{});
                            },
                            .not_equal => {
                                try self.writer.print("    setne al\n", .{});
                                try self.writer.print("    movzx rax, al\n", .{});
                            },
                            .lt => {
                                try self.writer.print("    setb al\n", .{});
                                try self.writer.print("    movzx rax, al\n", .{});
                            },
                            .gt => {
                                try self.writer.print("    seta al\n", .{});
                                try self.writer.print("    movzx rax, al\n", .{});
                            },
                            .lt_equal => {
                                try self.writer.print("    setbe al\n", .{});
                                try self.writer.print("    movzx rax, al\n", .{});
                            },
                            .gt_equal => {
                                try self.writer.print("    setae al\n", .{});
                                try self.writer.print("    movzx rax, al\n", .{});
                            },
                            else => unreachable,
                        }
                    } else {
                        // Integer comparison.
                        try self.writer.print("    mov rbx, rax\n", .{});
                        try self.writer.print("    pop rax\n", .{});
                        switch (b.op) {
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
                            else => unreachable,
                        }
                    }
                    return .int;
                } else {
                    // Pure integer arithmetic.
                    try self.writer.print("    mov rbx, rax\n", .{});
                    try self.writer.print("    pop rax\n", .{});
                    switch (b.op) {
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
                        .kw_and => {
                            try self.writer.print("    test rax, rax\n", .{});
                            try self.writer.print("    setne al\n", .{});
                            try self.writer.print("    movzx rax, al\n", .{});
                            try self.writer.print("    test rbx, rbx\n", .{});
                            try self.writer.print("    setne cl\n", .{});
                            try self.writer.print("    and al, cl\n", .{});
                            try self.writer.print("    movzx rax, al\n", .{});
                        },
                        .kw_or => {
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
                    return .int;
                }
            },
            .unary => |u| {
                const kind = try self.generateExpr(u.operand);
                switch (u.op) {
                    .bang => {
                        // Logical NOT works on truth value — convert float to int first if needed.
                        if (kind == .float) {
                            try self.writer.print("    xorpd xmm1, xmm1\n", .{});
                            try self.writer.print("    ucomisd xmm0, xmm1\n", .{});
                            try self.writer.print("    sete al\n", .{});
                            try self.writer.print("    movzx rax, al\n", .{});
                        } else {
                            try self.writer.print("    cmp rax, 0\n", .{});
                            try self.writer.print("    sete al\n", .{});
                            try self.writer.print("    movzx rax, al\n", .{});
                        }
                        return .int;
                    },
                    else => unreachable,
                }
            },
            else => {
                // For statement-level nodes called from generateNode, delegate back.
                try self.generateNode(node);
                return .int;
            },
        }
    }
};
