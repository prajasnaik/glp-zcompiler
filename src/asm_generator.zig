const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;
const DataType = parser.DataType;

const MapEntry = struct {
    label: []const u8,
    line: usize,
};

fn computeLine(source: []const u8, offset: usize) usize {
    var line: usize = 1;
    const end = @min(offset, source.len);
    for (source[0..end]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

/// The active "register" after evaluating a sub-expression.
/// .int    → result is in rax  (integer 64-bit)
/// .float  → result is in xmm0 (double-precision)
/// .string → result is in rax (pointer) and rdx (length)
pub const RegKind = enum { int, float, string };

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
    /// Primed slots to be emitted into the source map for debugger visibility.
    /// Keys are the base variable names; writeMap emits them as `<name>\``.
    prime_debug_slots: std.StringHashMap(VarInfo),
    stack_offset: i32,
    label_counter: u32,
    /// Set after generating the last top-level expression so the footer can
    /// choose the correct printf format string.
    result_kind: RegKind,
    source: []const u8,
    map_writer: ?*std.Io.Writer,
    stmt_counter: u32,
    map_statements: std.ArrayList(MapEntry),

    pub fn init(writer: *std.Io.Writer, allocator: std.mem.Allocator, source: []const u8, map_writer: ?*std.Io.Writer) !AsmGenerator {
        return .{
            .writer = writer,
            .allocator = allocator,
            .variables = std.StringHashMap(VarInfo).init(allocator),
            .prime_slots = std.StringHashMap(VarInfo).init(allocator),
            .prime_debug_slots = std.StringHashMap(VarInfo).init(allocator),
            .stack_offset = 0,
            .label_counter = 0,
            .result_kind = .int,
            .source = source,
            .map_writer = map_writer,
            .stmt_counter = 0,
            .map_statements = .empty,
        };
    }

    pub fn deinit(self: *AsmGenerator) void {
        for (self.map_statements.items) |entry| {
            self.allocator.free(entry.label);
        }
        self.map_statements.deinit(self.allocator);
        self.variables.deinit();
        self.prime_slots.deinit();
        self.prime_debug_slots.deinit();
    }

    pub fn generate(self: *AsmGenerator, root: *Node) !void {
        std.debug.print("[asm] generate: starting with root type={s}\n", .{@tagName(root.data)});
        // First pass: figure out whether the last expression produces a float
        // or string. We set result_kind before writing the header so the rodata
        // section can include the right format string.
        if (root.data == .block) {
            const stmts = root.data.block.statements;
            if (stmts.len > 0) {
                const last = stmts[stmts.len - 1];
                self.result_kind = resultKindOfNode(last);
            }
        }
        std.debug.print("[asm] generate: writing header (result_kind={s})...\n", .{@tagName(self.result_kind)});
        try self.printHeader();
        std.debug.print("[asm] generate: writing body...\n", .{});
        try self.generateNode(root);
        std.debug.print("[asm] generate: writing footer...\n", .{});
        try self.printFooter();
        std.debug.print("[asm] generate: writing source map...\n", .{});
        try self.writeMap();
        std.debug.print("[asm] generate: done\n", .{});
    }

    fn printHeader(self: *AsmGenerator) !void {
        // Choose the format string based on result type.
        if (self.result_kind == .float) {
            try self.writer.print(
                \\    .extern printf
                \\    .extern malloc
                \\    .extern memcpy
                \\    .extern strstr
                \\
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
        } else if (self.result_kind == .string) {
            try self.writer.print(
                \\    .extern printf
                \\    .extern malloc
                \\    .extern memcpy
                \\    .extern strstr
                \\
                \\    .intel_syntax noprefix
                \\    .section .rodata
                \\fmt:
                \\    .string "Result: %.*s\n"
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
                \\    .extern printf
                \\    .extern malloc
                \\    .extern memcpy
                \\    .extern strstr
                \\
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
        if (self.result_kind == .float) {
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
        } else if (self.result_kind == .string) {
            try self.writer.print(
                \\    lea rdi, [rip + fmt]    # First arg: format string
                \\    mov esi, edx            # Second arg: string length
                \\    mov rdx, rax            # Third arg: string pointer
                \\    xor eax, eax            # printf expects 0 in EAX for varargs
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

    fn writeMap(self: *AsmGenerator) !void {
        const mw = self.map_writer orelse return;
        try mw.print("{{\n  \"statements\": [\n", .{});
        for (self.map_statements.items, 0..) |entry, i| {
            if (i > 0) try mw.print(",\n", .{});
            try mw.print("    {{\"label\": \"{s}\", \"line\": {d}}}", .{ entry.label, entry.line });
        }
        try mw.print("\n  ],\n  \"variables\": {{\n", .{});
        var it = self.variables.iterator();
        var first = true;
        while (it.next()) |kv| {
            if (!first) try mw.print(",\n", .{});
            first = false;
            try mw.print("    \"{s}\": {{\"rbp_offset\": {d}, \"kind\": \"{s}\"}}", .{
                kv.key_ptr.*,
                kv.value_ptr.offset,
                @tagName(kv.value_ptr.kind),
            });
        }

        // Also emit primed slots for debugger reads as `<name>\`` entries.
        var pit = self.prime_debug_slots.iterator();
        while (pit.next()) |kv| {
            if (!first) try mw.print(",\n", .{});
            first = false;
            try mw.print("    \"{s}`\": {{\"rbp_offset\": {d}, \"kind\": \"{s}\"}}", .{
                kv.key_ptr.*,
                kv.value_ptr.offset,
                @tagName(kv.value_ptr.kind),
            });
        }
        try mw.print("\n  }}\n}}\n", .{});
    }

    fn emitByteList(self: *AsmGenerator, bytes: []const u8) !void {
        try self.writer.print("    .byte ", .{});
        var i: usize = 0;
        var first = true;
        while (i < bytes.len) : (i += 1) {
            var value = bytes[i];
            if (value == '\\' and i + 1 < bytes.len) {
                i += 1;
                value = switch (bytes[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    else => bytes[i],
                };
            }
            if (!first) try self.writer.print(", ", .{});
            first = false;
            try self.writer.print("{d}", .{value});
        }
        try self.writer.print("\n", .{});
    }

    fn buildPrintfFormat(self: *AsmGenerator, fmt_src: []const u8, arg_kinds: []const RegKind) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        var arg_index: usize = 0;
        var i: usize = 0;

        while (i < fmt_src.len) : (i += 1) {
            if (fmt_src[i] == '{' and i + 1 < fmt_src.len and fmt_src[i + 1] == '}') {
                if (arg_index >= arg_kinds.len) return error.PrintPlaceholderMismatch;
                switch (arg_kinds[arg_index]) {
                    .int => try out.appendSlice(self.allocator, "%ld"),
                    .string => try out.appendSlice(self.allocator, "%.*s"),
                    .float => return error.UnsupportedPrintFloatFormat,
                }
                arg_index += 1;
                i += 1;
                continue;
            }
            try out.append(self.allocator, fmt_src[i]);
        }

        if (arg_index != arg_kinds.len) return error.PrintPlaceholderMismatch;
        if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
            try out.append(self.allocator, '\n');
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn resultKindOfNode(node: *const Node) RegKind {
        return switch (node.data) {
            .literal => |lit| switch (lit) {
                .float => .float,
                .string => .string,
                else => .int,
            },
            .variable => |v| switch (v.data_type) {
                .float => .float,
                .string => .string,
                else => .int,
            },
            .binary => |b| switch (b.op) {
                // Comparison / logical → always int (0/1)
                .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal, .kw_and, .kw_or => .int,
                .plus => blk: {
                    const left_kind = resultKindOfNode(b.left);
                    const right_kind = resultKindOfNode(b.right);
                    if (left_kind == .string or right_kind == .string) break :blk .string;
                    if (left_kind == .float or right_kind == .float) break :blk .float;
                    break :blk .int;
                },
                else => blk: {
                    const left_kind = resultKindOfNode(b.left);
                    const right_kind = resultKindOfNode(b.right);
                    if (left_kind == .string or right_kind == .string) break :blk .string;
                    if (left_kind == .float or right_kind == .float) break :blk .float;
                    break :blk .int;
                },
            },
            .unary => |u| switch (u.op) {
                .bang => .int,
                .minus => resultKindOfNode(u.operand),
                else => .int,
            },
            .assignment => |a| resultKindOfNode(a.value),
            .prime_assignment => |pa| resultKindOfNode(pa.value),
            .call => |c| {
                if (std.mem.eql(u8, c.name, "find")) return .int;
                if (std.mem.eql(u8, c.name, "print")) return .int;
                return .int;
            },
            .index => .string,
            .slice => .string,
            .block => |bl| blk: {
                if (bl.statements.len == 0) break :blk .int;
                break :blk resultKindOfNode(bl.statements[bl.statements.len - 1]);
            },
            else => .int,
        };
    }

    fn generateNode(self: *AsmGenerator, node: *Node) !void {
        std.debug.print("[asm] generateNode: type={s}", .{@tagName(node.data)});

        switch (node.data) {
            .assignment => |a| std.debug.print(" target='{s}'", .{a.target}),
            .variable => |v| std.debug.print(" name='{s}' type={s}", .{ v.name, @tagName(v.data_type) }),
            .literal => |l| {
                switch (l) {
                    .int => |n| std.debug.print(" value(int)={d}", .{n}),
                    .float => |n| std.debug.print(" value(float)={d}", .{n}),
                    .string => |s| std.debug.print(" value(string_len)={d}", .{s.len}),
                    else => std.debug.print(" value=unsupported_literal", .{}),
                }
            },
            .binary => |b| std.debug.print(" op='{s}'", .{@tagName(b.op)}),
            .block => |b| std.debug.print(" stmts={d}", .{b.statements.len}),
            .unary => |u| std.debug.print(" op='{s}'", .{@tagName(u.op)}),
            .call => |c| std.debug.print(" call='{s}' argc={d}", .{ c.name, c.args.len }),
            .index => std.debug.print(" (index)", .{}),
            .slice => std.debug.print(" (slice)", .{}),
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
                    const line = computeLine(self.source, stmt.span.start);
                    const label = try std.fmt.allocPrint(self.allocator, "dpl_stmt_{d}", .{self.stmt_counter});
                    self.stmt_counter += 1;
                    try self.writer.print("    .globl {s}\n{s}:\n", .{ label, label });
                    try self.map_statements.append(self.allocator, .{ .label = label, .line = line });
                    try self.generateNode(stmt);
                }
            },
            .assignment => |a| {
                std.debug.print("[asm]   assignment: evaluating RHS for '{s}'\n", .{a.target});
                const kind = try self.generateExpr(a.value);
                self.stack_offset += if (kind == .string) 16 else 8;
                const info_offset: i32 = if (kind == .string) self.stack_offset - 8 else self.stack_offset;
                const info = VarInfo{ .offset = info_offset, .kind = kind };
                try self.variables.put(a.target, info);
                std.debug.print("[asm]   assignment: '{s}' stored at [rbp - {d}] ({s})\n", .{ a.target, info.offset, @tagName(kind) });
                switch (kind) {
                    .int => try self.writer.print("    mov [rbp - {d}], rax\n", .{info.offset}),
                    .float => try self.writer.print("    movsd [rbp - {d}], xmm0\n", .{info.offset}),
                    .string => {
                        try self.writer.print("    mov [rbp - {d}], rax\n", .{info.offset});
                        try self.writer.print("    mov [rbp - {d}], rdx\n", .{info.offset + 8});
                    },
                }
            },
            .variable => |name| {
                const info = self.variables.get(name.name).?;
                std.debug.print("[asm]   variable: '{s}' loaded from [rbp - {d}] ({s})\n", .{ name.name, info.offset, @tagName(info.kind) });
                switch (info.kind) {
                    .int => try self.writer.print("    mov rax, [rbp - {d}]\n", .{info.offset}),
                    .float => try self.writer.print("    movsd xmm0, [rbp - {d}]\n", .{info.offset}),
                    .string => {
                        try self.writer.print("    mov rax, [rbp - {d}]\n", .{info.offset});
                        try self.writer.print("    mov rdx, [rbp - {d}]\n", .{info.offset + 8});
                    },
                }
            },
            // Expressions: delegate to generateExpr (result discarded)
            .binary, .literal, .unary, .call, .index, .slice => {
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
                    const orig_info = self.variables.get(name) orelse VarInfo{ .offset = 0, .kind = .int };
                    self.stack_offset += if (orig_info.kind == .string) 16 else 8;
                    const slot_offset: i32 = if (orig_info.kind == .string) self.stack_offset - 8 else self.stack_offset;
                    const slot_info = VarInfo{ .offset = slot_offset, .kind = orig_info.kind };
                    try self.prime_slots.put(name, slot_info);
                    try self.prime_debug_slots.put(name, slot_info);
                    std.debug.print("[asm]   while_loop: prime slot for '{s}' at [rbp - {d}] ({s})\n", .{ name, slot_info.offset, @tagName(slot_info.kind) });
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
                        .string => {
                            try self.writer.print("    mov rax, [rbp - {d}]\n", .{new_info.offset});
                            try self.writer.print("    mov rdx, [rbp - {d}]\n", .{new_info.offset + 8});
                            try self.writer.print("    mov [rbp - {d}], rax\n", .{old_info.offset});
                            try self.writer.print("    mov [rbp - {d}], rdx\n", .{old_info.offset + 8});
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
                    .string => {
                        try self.writer.print("    mov [rbp - {d}], rax\n", .{new_info.offset});
                        try self.writer.print("    mov [rbp - {d}], rdx\n", .{new_info.offset + 8});
                    },
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
                    .string => |val| {
                        var label_buf: [32]u8 = undefined;
                        const label = try std.fmt.bufPrint(&label_buf, ".Lstr_{d}", .{self.label_counter});
                        self.label_counter += 1;

                        try self.writer.print("    .section .rodata\n{s}:\n", .{label});
                        try self.emitByteList(val);
                        try self.writer.print("    .byte 0\n", .{});
                        try self.writer.print("    .text\n", .{});

                        try self.writer.print("    mov rdi, {d}\n", .{val.len + 1});
                        try self.writer.print("    call malloc@PLT\n", .{});
                        try self.writer.print("    mov rdi, rax\n", .{});
                        try self.writer.print("    lea rsi, [rip + {s}]\n", .{label});
                        try self.writer.print("    mov rdx, {d}\n", .{val.len + 1});
                        try self.writer.print("    call memcpy@PLT\n", .{});
                        try self.writer.print("    mov rdx, {d}\n", .{val.len});
                        return .string;
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
                const info = self.variables.get(name.name).?;
                switch (info.kind) {
                    .int => {
                        try self.writer.print("    mov rax, [rbp - {d}]\n", .{info.offset});
                        return .int;
                    },
                    .float => {
                        try self.writer.print("    movsd xmm0, [rbp - {d}]\n", .{info.offset});
                        return .float;
                    },
                    .string => {
                        try self.writer.print("    mov rax, [rbp - {d}]\n", .{info.offset});
                        try self.writer.print("    mov rdx, [rbp - {d}]\n", .{info.offset + 8});
                        return .string;
                    },
                }
            },
            .call => |c| {
                if (std.mem.eql(u8, c.name, "find")) {
                    if (c.args.len != 2) return error.FindArityMismatch;

                    const hay_kind = try self.generateExpr(c.args[0]);
                    if (hay_kind != .string) return error.FindRequiresStrings;
                    self.stack_offset += 16;
                    const hay_ptr_off = self.stack_offset - 8;
                    const hay_len_off = self.stack_offset;
                    try self.writer.print("    mov [rbp - {d}], rax\n", .{hay_ptr_off});
                    try self.writer.print("    mov [rbp - {d}], rdx\n", .{hay_len_off});

                    const needle_kind = try self.generateExpr(c.args[1]);
                    if (needle_kind != .string) return error.FindRequiresStrings;
                    self.stack_offset += 16;
                    const needle_ptr_off = self.stack_offset - 8;
                    try self.writer.print("    mov [rbp - {d}], rax\n", .{needle_ptr_off});

                    const label_id = self.label_counter;
                    self.label_counter += 1;

                    try self.writer.print("    mov rdi, [rbp - {d}]\n", .{hay_ptr_off});
                    try self.writer.print("    mov rsi, [rbp - {d}]\n", .{needle_ptr_off});
                    try self.writer.print("    call strstr@PLT\n", .{});
                    try self.writer.print("    cmp rax, 0\n", .{});
                    try self.writer.print("    je .Lfind_not_{d}\n", .{label_id});
                    try self.writer.print("    sub rax, [rbp - {d}]\n", .{hay_ptr_off});
                    try self.writer.print("    jmp .Lfind_end_{d}\n", .{label_id});
                    try self.writer.print(".Lfind_not_{d}:\n", .{label_id});
                    try self.writer.print("    mov rax, -1\n", .{});
                    try self.writer.print(".Lfind_end_{d}:\n", .{label_id});
                    return .int;
                }

                if (std.mem.eql(u8, c.name, "print")) {
                    if (c.args.len == 0) return error.PrintArityMismatch;

                    const fmt_node = c.args[0];
                    const fmt_src = switch (fmt_node.data) {
                        .literal => |lit| switch (lit) {
                            .string => |s| s,
                            else => return error.PrintFormatMustBeStringLiteral,
                        },
                        else => return error.PrintFormatMustBeStringLiteral,
                    };

                    var arg_kinds: std.ArrayList(RegKind) = .empty;
                    defer arg_kinds.deinit(self.allocator);
                    for (c.args[1..]) |arg| {
                        try arg_kinds.append(self.allocator, resultKindOfNode(arg));
                    }

                    const final_fmt = try self.buildPrintfFormat(fmt_src, arg_kinds.items);
                    defer self.allocator.free(final_fmt);

                    var fmt_label_buf: [40]u8 = undefined;
                    const fmt_label = try std.fmt.bufPrint(&fmt_label_buf, ".Lprint_fmt_{d}", .{self.label_counter});
                    self.label_counter += 1;

                    try self.writer.print("    .section .rodata\n{s}:\n", .{fmt_label});
                    try self.emitByteList(final_fmt);
                    try self.writer.print("    .byte 0\n", .{});
                    try self.writer.print("    .text\n", .{});

                    var flat_offsets: std.ArrayList(i32) = .empty;
                    defer flat_offsets.deinit(self.allocator);

                    for (c.args[1..], arg_kinds.items) |arg, kind| {
                        const actual_kind = try self.generateExpr(arg);
                        if (actual_kind != kind) return error.PrintArgumentTypeMismatch;
                        switch (kind) {
                            .int => {
                                self.stack_offset += 8;
                                const off = self.stack_offset;
                                try self.writer.print("    mov [rbp - {d}], rax\n", .{off});
                                try flat_offsets.append(self.allocator, off);
                            },
                            .string => {
                                self.stack_offset += 16;
                                const ptr_off = self.stack_offset - 8;
                                const len_off = self.stack_offset;
                                try self.writer.print("    mov [rbp - {d}], rax\n", .{ptr_off});
                                try self.writer.print("    mov [rbp - {d}], rdx\n", .{len_off});
                                // printf for %.*s expects: precision then pointer
                                try flat_offsets.append(self.allocator, len_off);
                                try flat_offsets.append(self.allocator, ptr_off);
                            },
                            .float => return error.UnsupportedPrintFloatFormat,
                        }
                    }

                    const arg_regs = [_][]const u8{ "rsi", "rdx", "rcx", "r8", "r9" };
                    if (flat_offsets.items.len > arg_regs.len) return error.TooManyPrintArguments;

                    try self.writer.print("    lea rdi, [rip + {s}]\n", .{fmt_label});
                    for (flat_offsets.items, 0..) |off, idx| {
                        try self.writer.print("    mov {s}, [rbp - {d}]\n", .{ arg_regs[idx], off });
                    }
                    try self.writer.print("    xor eax, eax\n", .{});
                    try self.writer.print("    call printf@PLT\n", .{});
                    try self.writer.print("    mov rax, 0\n", .{});
                    return .int;
                }

                return error.UnknownFunction;
            },
            .index => |idx| {
                const target_kind = try self.generateExpr(idx.target);
                if (target_kind != .string) return error.IndexRequiresString;
                self.stack_offset += 16;
                const ptr_off = self.stack_offset - 8;
                const len_off = self.stack_offset;
                try self.writer.print("    mov [rbp - {d}], rax\n", .{ptr_off});
                try self.writer.print("    mov [rbp - {d}], rdx\n", .{len_off});

                const idx_kind = try self.generateExpr(idx.index);
                if (idx_kind != .int) return error.IndexMustBeInteger;

                const label_id = self.label_counter;
                self.label_counter += 1;

                try self.writer.print("    mov rcx, rax\n", .{});
                try self.writer.print("    cmp rcx, 0\n", .{});
                try self.writer.print("    jge .Lidx_nonneg_{d}\n", .{label_id});
                try self.writer.print("    add rcx, [rbp - {d}]\n", .{len_off});
                try self.writer.print(".Lidx_nonneg_{d}:\n", .{label_id});
                try self.writer.print("    cmp rcx, 0\n", .{});
                try self.writer.print("    jl .Lidx_oob_{d}\n", .{label_id});
                try self.writer.print("    cmp rcx, [rbp - {d}]\n", .{len_off});
                try self.writer.print("    jge .Lidx_oob_{d}\n", .{label_id});

                self.stack_offset += 8;
                const idx_off = self.stack_offset;
                try self.writer.print("    mov [rbp - {d}], rcx\n", .{idx_off});

                try self.writer.print("    mov rdi, 2\n", .{});
                try self.writer.print("    call malloc@PLT\n", .{});
                try self.writer.print("    mov rsi, [rbp - {d}]\n", .{ptr_off});
                try self.writer.print("    add rsi, [rbp - {d}]\n", .{idx_off});
                try self.writer.print("    mov bl, [rsi]\n", .{});
                try self.writer.print("    mov [rax], bl\n", .{});
                try self.writer.print("    mov byte ptr [rax + 1], 0\n", .{});
                try self.writer.print("    mov rdx, 1\n", .{});
                try self.writer.print("    jmp .Lidx_end_{d}\n", .{label_id});

                try self.writer.print(".Lidx_oob_{d}:\n", .{label_id});
                try self.writer.print("    mov rdi, 1\n", .{});
                try self.writer.print("    call malloc@PLT\n", .{});
                try self.writer.print("    mov byte ptr [rax], 0\n", .{});
                try self.writer.print("    mov rdx, 0\n", .{});
                try self.writer.print(".Lidx_end_{d}:\n", .{label_id});
                return .string;
            },
            .slice => |sl| {
                const target_kind = try self.generateExpr(sl.target);
                if (target_kind != .string) return error.SliceRequiresString;
                self.stack_offset += 16;
                const ptr_off = self.stack_offset - 8;
                const len_off = self.stack_offset;
                try self.writer.print("    mov [rbp - {d}], rax\n", .{ptr_off});
                try self.writer.print("    mov [rbp - {d}], rdx\n", .{len_off});

                var start_off: i32 = 0;
                var end_off: i32 = 0;

                if (sl.start) |start_expr| {
                    const start_kind = try self.generateExpr(start_expr);
                    if (start_kind != .int) return error.SliceBoundsMustBeInteger;
                    self.stack_offset += 8;
                    start_off = self.stack_offset;
                    try self.writer.print("    mov [rbp - {d}], rax\n", .{start_off});
                } else {
                    self.stack_offset += 8;
                    start_off = self.stack_offset;
                    try self.writer.print("    mov qword ptr [rbp - {d}], 0\n", .{start_off});
                }

                if (sl.end) |end_expr| {
                    const end_kind = try self.generateExpr(end_expr);
                    if (end_kind != .int) return error.SliceBoundsMustBeInteger;
                    self.stack_offset += 8;
                    end_off = self.stack_offset;
                    try self.writer.print("    mov [rbp - {d}], rax\n", .{end_off});
                } else {
                    self.stack_offset += 8;
                    end_off = self.stack_offset;
                    try self.writer.print("    mov rax, [rbp - {d}]\n", .{len_off});
                    try self.writer.print("    mov [rbp - {d}], rax\n", .{end_off});
                }

                const label_id = self.label_counter;
                self.label_counter += 1;

                // Normalize and clamp start in rcx.
                try self.writer.print("    mov rcx, [rbp - {d}]\n", .{start_off});
                try self.writer.print("    cmp rcx, 0\n", .{});
                try self.writer.print("    jge .Lslice_start_nonneg_{d}\n", .{label_id});
                try self.writer.print("    add rcx, [rbp - {d}]\n", .{len_off});
                try self.writer.print(".Lslice_start_nonneg_{d}:\n", .{label_id});
                try self.writer.print("    cmp rcx, 0\n", .{});
                try self.writer.print("    jge .Lslice_start_min_ok_{d}\n", .{label_id});
                try self.writer.print("    mov rcx, 0\n", .{});
                try self.writer.print(".Lslice_start_min_ok_{d}:\n", .{label_id});
                try self.writer.print("    cmp rcx, [rbp - {d}]\n", .{len_off});
                try self.writer.print("    jle .Lslice_start_max_ok_{d}\n", .{label_id});
                try self.writer.print("    mov rcx, [rbp - {d}]\n", .{len_off});
                try self.writer.print(".Lslice_start_max_ok_{d}:\n", .{label_id});

                // Normalize and clamp end in r8.
                try self.writer.print("    mov r8, [rbp - {d}]\n", .{end_off});
                try self.writer.print("    cmp r8, 0\n", .{});
                try self.writer.print("    jge .Lslice_end_nonneg_{d}\n", .{label_id});
                try self.writer.print("    add r8, [rbp - {d}]\n", .{len_off});
                try self.writer.print(".Lslice_end_nonneg_{d}:\n", .{label_id});
                try self.writer.print("    cmp r8, 0\n", .{});
                try self.writer.print("    jge .Lslice_end_min_ok_{d}\n", .{label_id});
                try self.writer.print("    mov r8, 0\n", .{});
                try self.writer.print(".Lslice_end_min_ok_{d}:\n", .{label_id});
                try self.writer.print("    cmp r8, [rbp - {d}]\n", .{len_off});
                try self.writer.print("    jle .Lslice_end_max_ok_{d}\n", .{label_id});
                try self.writer.print("    mov r8, [rbp - {d}]\n", .{len_off});
                try self.writer.print(".Lslice_end_max_ok_{d}:\n", .{label_id});

                // Ensure end >= start.
                try self.writer.print("    cmp r8, rcx\n", .{});
                try self.writer.print("    jge .Lslice_order_ok_{d}\n", .{label_id});
                try self.writer.print("    mov r8, rcx\n", .{});
                try self.writer.print(".Lslice_order_ok_{d}:\n", .{label_id});

                // r9 = new length
                try self.writer.print("    mov r9, r8\n", .{});
                try self.writer.print("    sub r9, rcx\n", .{});

                self.stack_offset += 16;
                const norm_start_off = self.stack_offset - 8;
                const norm_len_off = self.stack_offset;
                try self.writer.print("    mov [rbp - {d}], rcx\n", .{norm_start_off});
                try self.writer.print("    mov [rbp - {d}], r9\n", .{norm_len_off});

                // malloc(new_len + 1)
                try self.writer.print("    mov rdi, [rbp - {d}]\n", .{norm_len_off});
                try self.writer.print("    add rdi, 1\n", .{});
                try self.writer.print("    call malloc@PLT\n", .{});

                // memcpy(dest=rax, src=ptr+start, len=new_len)
                try self.writer.print("    mov rdi, rax\n", .{});
                try self.writer.print("    mov rsi, [rbp - {d}]\n", .{ptr_off});
                try self.writer.print("    add rsi, [rbp - {d}]\n", .{norm_start_off});
                try self.writer.print("    mov rdx, [rbp - {d}]\n", .{norm_len_off});
                try self.writer.print("    call memcpy@PLT\n", .{});

                // Null terminator + returned logical length in rdx
                try self.writer.print("    mov rdx, [rbp - {d}]\n", .{norm_len_off});
                try self.writer.print("    mov byte ptr [rax + rdx], 0\n", .{});
                return .string;
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
                    .string => {},
                }

                const right_kind = try self.generateExpr(b.right);

                const has_string = left_kind == .string or right_kind == .string;
                if (has_string and b.op != .plus) {
                    return error.UnsupportedStringOperation;
                }

                // Promote mixed int/float: if one is float, convert the other.
                const result_kind: RegKind = blk: {
                    switch (b.op) {
                        // Comparisons / logical always produce an int result.
                        .plus => {
                            if (has_string) break :blk .string;
                            break :blk if (left_kind == .float or right_kind == .float) .float else .int;
                        },
                        .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal, .kw_and, .kw_or => break :blk .int,
                        else => break :blk if (left_kind == .float or right_kind == .float) .float else .int,
                    }
                };

                if (result_kind == .string) {
                    if (left_kind != .string or right_kind != .string) {
                        return error.StringOperationRequiresStrings;
                    }
                    if (b.op != .plus) {
                        return error.UnsupportedStringOperation;
                    }

                    try self.writer.print("    sub rsp, 32\n", .{});
                    try self.writer.print("    mov [rsp + 16], rax\n", .{});
                    try self.writer.print("    mov [rsp + 24], rdx\n", .{});
                    try self.writer.print("    mov [rsp], rax\n", .{});
                    try self.writer.print("    mov [rsp + 8], rdx\n", .{});

                    try self.writer.print("    mov rdi, [rsp + 24]\n", .{});
                    try self.writer.print("    add rdi, [rsp + 8]\n", .{});
                    try self.writer.print("    add rdi, 1\n", .{});
                    try self.writer.print("    call malloc@PLT\n", .{});

                    try self.writer.print("    mov rdi, rax\n", .{});
                    try self.writer.print("    mov rsi, [rsp + 16]\n", .{});
                    try self.writer.print("    mov rdx, [rsp + 24]\n", .{});
                    try self.writer.print("    call memcpy@PLT\n", .{});

                    try self.writer.print("    mov rdi, rax\n", .{});
                    try self.writer.print("    add rdi, [rsp + 24]\n", .{});
                    try self.writer.print("    mov rsi, [rsp]\n", .{});
                    try self.writer.print("    mov rdx, [rsp + 8]\n", .{});
                    try self.writer.print("    call memcpy@PLT\n", .{});

                    try self.writer.print("    mov rdx, [rsp + 24]\n", .{});
                    try self.writer.print("    add rdx, [rsp + 8]\n", .{});
                    try self.writer.print("    mov byte ptr [rax + rdx], 0\n", .{});
                    try self.writer.print("    add rsp, 32\n", .{});
                    return .string;
                }

                if (result_kind == .float) {
                    // Pop left into xmm1, ensure right is in xmm0.
                    switch (right_kind) {
                        .int => {
                            // right is in rax → xmm0
                            try self.writer.print("    cvtsi2sd xmm0, rax\n", .{});
                        },
                        .float => {}, // right already in xmm0
                        .string => unreachable,
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
                    .minus => {
                        if (kind == .float) {
                            try self.writer.print("    xorpd xmm1, xmm1\n", .{});
                            try self.writer.print("    subsd xmm1, xmm0\n", .{});
                            try self.writer.print("    movapd xmm0, xmm1\n", .{});
                        } else {
                            try self.writer.print("    neg rax\n", .{});
                        }
                        return kind;
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
