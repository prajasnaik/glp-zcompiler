const std = @import("std");

pub fn main() !void {
    const input = "1 * a2 + 5) * 40 * 9";

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

// --- Parser with Pratt Algorithm for Operator Precedence ---

const Node = struct {
    isOperator: bool,
    operator: ?u8,
    operand: ?f32,
    left: ?*Node,
    right: ?*Node,
};

// Binding power: higher = tighter binding
fn getBindingPower(op: u8) usize {
    return switch (op) {
        '+', '-' => 1,
        '*', '/' => 2,
        '^' => 3,
        else => 0,
    };
}

const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    fn init(input: []const u8, allocator: std.mem.Allocator) Parser {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
        };
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and std.mem.indexOfScalar(u8, " \t\n\r", self.input[self.pos]) != null) {
            self.pos += 1;
        }
    }

    fn peek(self: *Parser) ?u8 {
        self.skipWhitespace();
        if (self.pos < self.input.len) {
            return self.input[self.pos];
        }
        return null;
    }

    fn consume(self: *Parser) ?u8 {
        const ch = self.peek();
        if (ch != null) {
            self.pos += 1;
        }
        return ch;
    }

    fn parseNumber(self: *Parser) (std.mem.Allocator.Error || std.fmt.ParseFloatError || error{UnmatchedParenthesis})!*Node {
        self.skipWhitespace();
        const start = self.pos;

        // Parse digits and decimal point
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if ((ch >= '0' and ch <= '9') or ch == '.') {
                self.pos += 1;
            } else {
                break;
            }
        }

        const numStr = self.input[start..self.pos];
        const node = try self.allocator.create(Node);
        node.* = .{
            .isOperator = false,
            .operator = null,
            .operand = try std.fmt.parseFloat(f32, numStr),
            .left = null,
            .right = null,
        };
        return node;
    }

    fn parseExpression(self: *Parser, minPower: usize) (std.mem.Allocator.Error || std.fmt.ParseFloatError || error{UnmatchedParenthesis})!*Node {
        // Check for parenthesized expression first
        var left: *Node = undefined;

        self.skipWhitespace();

        if (self.peek() == '(') {
            _ = self.consume(); // consume '('
            left = try self.parseExpression(0);
            self.skipWhitespace();
            if (self.consume() != ')') {
                return error.UnmatchedParenthesis;
            }
        } else {
            left = try self.parseNumber();
        }
        self.skipWhitespace();

        while (self.peek()) |op| {
            const power = getBindingPower(op);

            if (power == 0 or power < minPower) {
                break;
            }
            _ = self.consume(); // consume the operator

            // For left-associative operators, parse right side with power + 1
            const right = try self.parseExpression(power + 1);

            const node = try self.allocator.create(Node);
            node.* = .{
                .isOperator = true,
                .operator = op,
                .operand = null,
                .left = left,
                .right = right,
            };
            left = node;
        }

        return left;
    }
};

pub fn arithmeticParse(str: []const u8, allocator: std.mem.Allocator) !*Node {
    var parser = Parser.init(str, allocator);
    return parser.parseExpression(0);
}
