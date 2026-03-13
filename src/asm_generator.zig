//! AST-to-assembly backend for GLP-ZCompiler.
//! Emits Intel-syntax x86-64 Linux assembly and handles int/float code paths.
const std = @import("std");
const parser = @import("parser.zig");
const DataType = parser.DataType;
const FunctionParam = parser.FunctionParam;
const Node = parser.Node;

/// The active "register" after evaluating a sub-expression.
/// .int  → result is in rax  (integer 64-bit)
/// .float → result is in xmm0 (double-precision)
pub const RegKind = enum { int, float };

/// Tracks where a variable lives on the stack and whether it holds a float or int.
const VarInfo = struct {
    offset: i32,
    kind: RegKind,
};

const ScopeBinding = struct {
    name: []const u8,
    previous: ?VarInfo,
};

const frame_size: i32 = 4096;

pub const AsmGenerator = struct {
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    variables: std.StringHashMap(VarInfo),
    prime_slots: std.StringHashMap(VarInfo),
    scope_stack: std.ArrayList(std.ArrayList(ScopeBinding)),
    stack_offset: i32,
    label_counter: u32,
    last_result_kind: RegKind,
    current_return_label: ?u32,
    current_function_return_type: ?DataType,

    /// Create a backend instance bound to an output writer.
    pub fn init(writer: *std.Io.Writer, allocator: std.mem.Allocator) !AsmGenerator {
        return .{
            .writer = writer,
            .allocator = allocator,
            .variables = std.StringHashMap(VarInfo).init(allocator),
            .prime_slots = std.StringHashMap(VarInfo).init(allocator),
            .scope_stack = .empty,
            .stack_offset = 0,
            .label_counter = 0,
            .last_result_kind = .int,
            .current_return_label = null,
            .current_function_return_type = null,
        };
    }

    /// Release backend-side maps and temporary state.
    pub fn deinit(self: *AsmGenerator) void {
        for (self.scope_stack.items) |*scope| scope.deinit(self.allocator);
        self.scope_stack.deinit(self.allocator);
        self.variables.deinit();
        self.prime_slots.deinit();
    }

    /// Generate a complete assembly program from AST root.
    pub fn generate(self: *AsmGenerator, root: *Node) anyerror!void {
        std.debug.print("[asm] generate: starting with root type={s}\n", .{@tagName(root.data)});
        try self.printPreamble();

        if (root.data == .block) {
            for (root.data.block.statements) |stmt| {
                if (stmt.data == .function_def) {
                    try self.generateFunction(stmt);
                }
            }
        }

        try self.printMainPrologue();
        try self.resetFunctionState();
        try self.beginScope();

        var executed_top_level = false;
        if (root.data == .block) {
            for (root.data.block.statements) |stmt| {
                if (stmt.data == .function_def) continue;
                self.last_result_kind = try self.generateNode(stmt);
                executed_top_level = true;
            }
        } else {
            self.last_result_kind = try self.generateNode(root);
            executed_top_level = true;
        }

        if (!executed_top_level) {
            try self.writer.print("    mov rax, 0\n", .{});
            self.last_result_kind = .int;
        }

        try self.endScope();
        try self.printMainFooter();
        std.debug.print("[asm] generate: done\n", .{});
    }

    fn printPreamble(self: *AsmGenerator) anyerror!void {
        try self.writer.print(
            \\    .intel_syntax noprefix
            \\    .section .rodata
            \\fmt_int:
            \\    .string "Result: %ld\n"
            \\fmt_float:
            \\    .string "Result: %f\n"
            \\
            \\    .section .text
            \\
        , .{});
    }

    fn printMainPrologue(self: *AsmGenerator) anyerror!void {
        try self.writer.print(
            \\    .globl main
            \\
            \\main:
            \\    push rbp
            \\    mov rbp, rsp
            \\    sub rsp, {d}
            \\
        , .{frame_size});
    }

    fn printMainFooter(self: *AsmGenerator) anyerror!void {
        if (self.last_result_kind == .float) {
            try self.writer.print(
                \\    lea rdi, [rip + fmt_float]
                \\    mov eax, 1
                \\    call printf@PLT
                \\
                \\    xor eax, eax
                \\    leave
                \\    ret
                \\
            , .{});
        } else {
            try self.writer.print(
                \\    lea rdi, [rip + fmt_int]
                \\    mov rsi, rax
                \\    xor eax, eax
                \\    call printf@PLT
                \\
                \\    xor eax, eax
                \\    leave
                \\    ret
                \\
            , .{});
        }
    }

    fn resetFunctionState(self: *AsmGenerator) anyerror!void {
        self.variables.clearRetainingCapacity();
        self.prime_slots.clearRetainingCapacity();
        for (self.scope_stack.items) |*scope| scope.deinit(self.allocator);
        self.scope_stack.clearRetainingCapacity();
        self.stack_offset = 0;
        self.last_result_kind = .int;
        self.current_return_label = null;
        self.current_function_return_type = null;
    }

    fn beginScope(self: *AsmGenerator) anyerror!void {
        try self.scope_stack.append(self.allocator, .empty);
    }

    fn endScope(self: *AsmGenerator) anyerror!void {
        var scope = self.scope_stack.pop().?;
        defer scope.deinit(self.allocator);

        var i = scope.items.len;
        while (i > 0) {
            i -= 1;
            const binding = scope.items[i];
            if (binding.previous) |previous| {
                try self.variables.put(binding.name, previous);
            } else {
                _ = self.variables.remove(binding.name);
            }
        }
    }

    fn bindVariable(self: *AsmGenerator, name: []const u8, info: VarInfo) anyerror!void {
        const previous = self.variables.get(name);
        try self.scope_stack.items[self.scope_stack.items.len - 1].append(self.allocator, .{
            .name = name,
            .previous = previous,
        });
        try self.variables.put(name, info);
    }

    fn reserveSlot(self: *AsmGenerator, kind: RegKind) anyerror!VarInfo {
        self.stack_offset += 8;
        if (self.stack_offset > frame_size) return error.StackFrameTooLarge;
        return .{ .offset = self.stack_offset, .kind = kind };
    }

    fn dataTypeToRegKind(ty: DataType) RegKind {
        return switch (ty) {
            .float => .float,
            else => .int,
        };
    }

    fn nodeType(node: *const Node) DataType {
        return switch (node.data) {
            .literal => |lit| switch (lit) {
                .float => .float,
                .boolean => .boolean,
                .string => .string,
                else => .int,
            },
            .variable => |var_ref| var_ref.ty,
            .function_call => |call| call.return_type,
            .assignment => |assign| nodeType(assign.value),
            .prime_assignment => |assign| nodeType(assign.value),
            .unary => .boolean,
            .binary => |binary| switch (binary.op) {
                .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal, .kw_and, .kw_or => .boolean,
                else => blk: {
                    const left_ty = nodeType(binary.left);
                    const right_ty = nodeType(binary.right);
                    break :blk if (left_ty == .float or right_ty == .float) .float else .int;
                },
            },
            .block => |block| blk: {
                if (block.statements.len == 0) break :blk .int;
                break :blk nodeType(block.statements[block.statements.len - 1]);
            },
            .if_statement => |stmt| nodeType(stmt.then_branch),
            else => .int,
        };
    }

    fn convertResultToType(self: *AsmGenerator, from: RegKind, to: DataType) anyerror!RegKind {
        const target = dataTypeToRegKind(to);
        if (from == target) return from;

        switch (target) {
            .float => {
                try self.writer.print("    cvtsi2sd xmm0, rax\n", .{});
                return .float;
            },
            .int => {
                try self.writer.print("    cvttsd2si rax, xmm0\n", .{});
                return .int;
            },
        }
    }

    fn generateFunction(self: *AsmGenerator, node: *Node) anyerror!void {
        const function = node.data.function_def;
        std.debug.print("[asm] generateFunction: {s}\n", .{function.name});

        try self.resetFunctionState();
        try self.beginScope();

        try self.writer.print(
            \\    .globl {s}
            \\{s}:
            \\    push rbp
            \\    mov rbp, rsp
            \\    sub rsp, {d}
            \\
        , .{ function.name, function.name, frame_size });

        const return_label_id = self.label_counter;
        self.label_counter += 1;
        self.current_return_label = return_label_id;
        self.current_function_return_type = function.return_type;

        try self.bindParameters(function.params);
        _ = try self.generateFunctionBody(function.body);

        try self.writer.print(".Lfn_return_{d}:\n", .{return_label_id});
        try self.endScope();
        try self.writer.print(
            \\    leave
            \\    ret
            \\
        , .{});

        self.current_return_label = null;
        self.current_function_return_type = null;
    }

    fn bindParameters(self: *AsmGenerator, params: []const FunctionParam) anyerror!void {
        const int_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };
        const float_regs = [_][]const u8{ "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7" };
        var int_index: usize = 0;
        var float_index: usize = 0;

        for (params) |param| {
            const kind = dataTypeToRegKind(param.ty);
            const slot = try self.reserveSlot(kind);
            try self.bindVariable(param.name, slot);
            switch (kind) {
                .int => {
                    if (int_index >= int_regs.len) return error.UnsupportedFunctionParameterCount;
                    try self.writer.print("    mov [rbp - {d}], {s}\n", .{ slot.offset, int_regs[int_index] });
                    int_index += 1;
                },
                .float => {
                    if (float_index >= float_regs.len) return error.UnsupportedFunctionParameterCount;
                    try self.writer.print("    movsd [rbp - {d}], {s}\n", .{ slot.offset, float_regs[float_index] });
                    float_index += 1;
                },
            }
        }
    }

    fn generateFunctionBody(self: *AsmGenerator, body: *Node) anyerror!RegKind {
        return switch (body.data) {
            .block => |block| try self.generateBlockStatements(block.statements, false),
            else => try self.generateNode(body),
        };
    }

    fn generateBlockStatements(self: *AsmGenerator, statements: []const *Node, create_scope: bool) anyerror!RegKind {
        if (create_scope) try self.beginScope();
        defer if (create_scope) self.endScope() catch {};

        var last_kind: RegKind = .int;
        if (statements.len == 0) {
            try self.writer.print("    mov rax, 0\n", .{});
            return .int;
        }

        for (statements) |stmt| {
            last_kind = try self.generateNode(stmt);
        }
        return last_kind;
    }

    fn generateNode(self: *AsmGenerator, node: *Node) anyerror!RegKind {
        std.debug.print("[asm] generateNode: type={s}\n", .{@tagName(node.data)});

        switch (node.data) {
            .block => |block| return self.generateBlockStatements(block.statements, true),
            .assignment => |assign| {
                const kind = try self.generateExpr(assign.value);
                const slot = try self.reserveSlot(kind);
                try self.bindVariable(assign.target, slot);
                switch (kind) {
                    .int => try self.writer.print("    mov [rbp - {d}], rax\n", .{slot.offset}),
                    .float => try self.writer.print("    movsd [rbp - {d}], xmm0\n", .{slot.offset}),
                }
                return kind;
            },
            .variable, .binary, .literal, .unary, .function_call => return self.generateExpr(node),
            .if_statement => |if_stmt| {
                const label_id = self.label_counter;
                self.label_counter += 1;

                _ = try self.generateExpr(if_stmt.condition);
                try self.writer.print("    cmp rax, 0\n", .{});

                if (if_stmt.else_branch) |else_branch| {
                    try self.writer.print("    je .Lelse_{d}\n", .{label_id});
                    const then_kind = try self.generateNode(if_stmt.then_branch);
                    try self.writer.print("    jmp .Lend_{d}\n", .{label_id});
                    try self.writer.print(".Lelse_{d}:\n", .{label_id});
                    const else_kind = try self.generateNode(else_branch);
                    if (then_kind != else_kind) return error.MismatchedBranchResultKinds;
                    try self.writer.print(".Lend_{d}:\n", .{label_id});
                    return then_kind;
                }

                try self.writer.print("    je .Lend_{d}\n", .{label_id});
                _ = try self.generateNode(if_stmt.then_branch);
                try self.writer.print(".Lend_{d}:\n", .{label_id});
                try self.writer.print("    mov rax, 0\n", .{});
                return .int;
            },
            .while_loop => |wl| {
                const label_id = self.label_counter;
                self.label_counter += 1;

                var previous_slots: std.ArrayList(struct {
                    name: []const u8,
                    previous: ?VarInfo,
                }) = .empty;
                defer previous_slots.deinit(self.allocator);

                for (wl.prime_vars) |name| {
                    const orig_info = self.variables.get(name) orelse return error.UndefinedVariable;
                    const slot = try self.reserveSlot(orig_info.kind);
                    try previous_slots.append(self.allocator, .{ .name = name, .previous = self.prime_slots.get(name) });
                    try self.prime_slots.put(name, slot);
                }
                defer {
                    var i = previous_slots.items.len;
                    while (i > 0) {
                        i -= 1;
                        const prev = previous_slots.items[i];
                        if (prev.previous) |info| {
                            self.prime_slots.put(prev.name, info) catch {};
                        } else {
                            _ = self.prime_slots.remove(prev.name);
                        }
                    }
                }

                try self.writer.print(".Lloop_start_{d}:\n", .{label_id});
                _ = try self.generateExpr(wl.condition);
                try self.writer.print("    cmp rax, 0\n", .{});
                try self.writer.print("    je .Lloop_end_{d}\n", .{label_id});

                _ = try self.generateNode(wl.body);

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
                try self.writer.print("    mov rax, 0\n", .{});
                return .int;
            },
            .prime_assignment => |assign| {
                const kind = try self.generateExpr(assign.value);
                const slot = self.prime_slots.get(assign.target).?;
                switch (kind) {
                    .int => try self.writer.print("    mov [rbp - {d}], rax\n", .{slot.offset}),
                    .float => try self.writer.print("    movsd [rbp - {d}], xmm0\n", .{slot.offset}),
                }
                return kind;
            },
            .return_statement => |ret_stmt| {
                const ret_kind = try self.generateExpr(ret_stmt.value);
                const expected = self.current_function_return_type orelse return error.ReturnOutsideFunction;
                _ = try self.convertResultToType(ret_kind, expected);
                const label_id = self.current_return_label orelse return error.ReturnOutsideFunction;
                try self.writer.print("    jmp .Lfn_return_{d}\n", .{label_id});
                return dataTypeToRegKind(expected);
            },
            .function_def => return .int,
        }
    }

    /// Generate code for an expression node. Returns RegKind indicating
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
                        const bits: u64 = @bitCast(val);
                        try self.writer.print("    mov rax, {d}    # float bits: {d}\n", .{ bits, val });
                        try self.writer.print("    movq xmm0, rax\n", .{});
                        return .float;
                    },
                    .boolean => |val| {
                        try self.writer.print("    mov rax, {d}\n", .{@as(i64, if (val) 1 else 0)});
                        return .int;
                    },
                    else => return error.UnsupportedLiteralType,
                }
            },
            .variable => |var_ref| {
                const info = self.variables.get(var_ref.name).?;
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
            .function_call => |call| return self.generateCall(call.name, call.args, call.param_types, call.return_type),
            .binary => |b| {
                const left_kind = try self.generateExpr(b.left);

                switch (left_kind) {
                    .int => try self.writer.print("    push rax\n", .{}),
                    .float => {
                        try self.writer.print("    sub rsp, 8\n", .{});
                        try self.writer.print("    movsd [rsp], xmm0\n", .{});
                    },
                }

                const right_kind = try self.generateExpr(b.right);
                const result_kind: RegKind = blk: {
                    switch (b.op) {
                        .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal, .kw_and, .kw_or => break :blk .int,
                        else => break :blk if (left_kind == .float or right_kind == .float) .float else .int,
                    }
                };

                if (result_kind == .float) {
                    switch (right_kind) {
                        .int => try self.writer.print("    cvtsi2sd xmm0, rax\n", .{}),
                        .float => {},
                    }
                    if (left_kind == .int) {
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
                            try self.writer.print("    movapd xmm0, xmm1\n", .{});
                            try self.writer.print("    call pow@PLT\n", .{});
                        },
                        else => unreachable,
                    }

                    switch (b.op) {
                        .caret => {},
                        else => try self.writer.print("    movapd xmm0, xmm1\n", .{}),
                    }
                    return .float;
                }

                if (b.op == .equal_equal or b.op == .not_equal or b.op == .lt or b.op == .gt or b.op == .lt_equal or b.op == .gt_equal) {
                    if (left_kind == .float or right_kind == .float) {
                        if (right_kind == .int) {
                            try self.writer.print("    cvtsi2sd xmm1, rax\n", .{});
                        } else {
                            try self.writer.print("    movapd xmm1, xmm0\n", .{});
                        }
                        if (left_kind == .int) {
                            try self.writer.print("    pop rax\n", .{});
                            try self.writer.print("    cvtsi2sd xmm0, rax\n", .{});
                        } else {
                            try self.writer.print("    movsd xmm0, [rsp]\n", .{});
                            try self.writer.print("    add rsp, 8\n", .{});
                        }
                        try self.writer.print("    ucomisd xmm0, xmm1\n", .{});
                        switch (b.op) {
                            .equal_equal => try self.writer.print("    sete al\n", .{}),
                            .not_equal => try self.writer.print("    setne al\n", .{}),
                            .lt => try self.writer.print("    setb al\n", .{}),
                            .gt => try self.writer.print("    seta al\n", .{}),
                            .lt_equal => try self.writer.print("    setbe al\n", .{}),
                            .gt_equal => try self.writer.print("    setae al\n", .{}),
                            else => unreachable,
                        }
                        try self.writer.print("    movzx rax, al\n", .{});
                    } else {
                        try self.writer.print("    mov r10, rax\n", .{});
                        try self.writer.print("    pop rax\n", .{});
                        try self.writer.print("    cmp rax, r10\n", .{});
                        switch (b.op) {
                            .equal_equal => try self.writer.print("    sete al\n", .{}),
                            .not_equal => try self.writer.print("    setne al\n", .{}),
                            .lt => try self.writer.print("    setl al\n", .{}),
                            .gt => try self.writer.print("    setg al\n", .{}),
                            .lt_equal => try self.writer.print("    setle al\n", .{}),
                            .gt_equal => try self.writer.print("    setge al\n", .{}),
                            else => unreachable,
                        }
                        try self.writer.print("    movzx rax, al\n", .{});
                    }
                    return .int;
                }

                try self.writer.print("    mov r10, rax\n", .{});
                try self.writer.print("    pop rax\n", .{});
                switch (b.op) {
                    .plus => try self.writer.print("    add rax, r10\n", .{}),
                    .minus => try self.writer.print("    sub rax, r10\n", .{}),
                    .star => try self.writer.print("    imul rax, r10\n", .{}),
                    .slash => {
                        try self.writer.print("    cqo\n", .{});
                        try self.writer.print("    idiv r10\n", .{});
                    },
                    .caret => {
                        try self.writer.print("    cvtsi2sd xmm0, rax\n", .{});
                        try self.writer.print("    cvtsi2sd xmm1, r10\n", .{});
                        try self.writer.print("    call pow@PLT\n", .{});
                        try self.writer.print("    cvttsd2si rax, xmm0\n", .{});
                    },
                    .kw_and => {
                        try self.writer.print("    test rax, rax\n", .{});
                        try self.writer.print("    setne al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                        try self.writer.print("    test r10, r10\n", .{});
                        try self.writer.print("    setne r11b\n", .{});
                        try self.writer.print("    and al, r11b\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    .kw_or => {
                        try self.writer.print("    test rax, rax\n", .{});
                        try self.writer.print("    setne al\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                        try self.writer.print("    test r10, r10\n", .{});
                        try self.writer.print("    setne r11b\n", .{});
                        try self.writer.print("    or al, r11b\n", .{});
                        try self.writer.print("    movzx rax, al\n", .{});
                    },
                    else => unreachable,
                }
                return .int;
            },
            .unary => |u| {
                const kind = try self.generateExpr(u.operand);
                switch (u.op) {
                    .bang => {
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
            else => return self.generateNode(node),
        }
    }

    fn generateCall(self: *AsmGenerator, name: []const u8, args: []const *Node, param_types: []const DataType, return_type: DataType) anyerror!RegKind {
        const int_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };
        const float_regs = [_][]const u8{ "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7" };
        var int_count: usize = 0;
        var float_count: usize = 0;

        var i = args.len;
        while (i > 0) {
            i -= 1;
            const arg_kind = try self.generateExpr(args[i]);
            const converted = try self.convertResultToType(arg_kind, param_types[i]);
            switch (converted) {
                .int => try self.writer.print("    push rax\n", .{}),
                .float => {
                    try self.writer.print("    sub rsp, 8\n", .{});
                    try self.writer.print("    movsd [rsp], xmm0\n", .{});
                },
            }
        }

        for (param_types) |param_type| {
            const kind = dataTypeToRegKind(param_type);
            switch (kind) {
                .int => {
                    if (int_count >= int_regs.len) return error.UnsupportedFunctionParameterCount;
                    try self.writer.print("    pop {s}\n", .{int_regs[int_count]});
                    int_count += 1;
                },
                .float => {
                    if (float_count >= float_regs.len) return error.UnsupportedFunctionParameterCount;
                    try self.writer.print("    movsd {s}, [rsp]\n", .{float_regs[float_count]});
                    try self.writer.print("    add rsp, 8\n", .{});
                    float_count += 1;
                },
            }
        }

        try self.writer.print("    call {s}\n", .{name});
        if (return_type == .void) {
            try self.writer.print("    mov rax, 0\n", .{});
            return .int;
        }
        return dataTypeToRegKind(return_type);
    }
};
