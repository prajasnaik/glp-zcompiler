const std = @import("std");

pub const Node = struct {
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

fn isRightAssociative(op: u8) bool {
    return op == '^'; // Exponentiation is right-associative
}

pub const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) Parser {
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

    fn parseNumber(self: *Parser) (std.mem.Allocator.Error || std.fmt.ParseFloatError || error{ UnmatchedParenthesis, UnexpectedCharacter })!*Node {
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
        if (numStr.len == 0) {
            const ch = self.peek() orelse 0;
            std.debug.print("\nSyntax Error: Expected a number but found '{c}' at position {d}\n", .{ ch, self.pos });
            return error.UnexpectedCharacter;
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .isOperator = false,
            .operator = null,
            .operand = std.fmt.parseFloat(f32, numStr) catch |err| {
                std.debug.print("\nSyntax Error: Invalid number format '{s}' at position {d}\n", .{ numStr, start });
                return err;
            },
            .left = null,
            .right = null,
        };
        return node;
    }

    fn parseExpression(self: *Parser, minPower: usize) (std.mem.Allocator.Error || std.fmt.ParseFloatError || error{ UnmatchedParenthesis, UnexpectedCharacter })!*Node {
        // Check for parenthesized expression first
        var left: *Node = undefined;

        self.skipWhitespace();

        if (self.peek() == '(') {
            _ = self.consume(); // consume '('
            left = try self.parseExpression(0);
            self.skipWhitespace();
            if (self.consume() != ')') {
                std.debug.print("\nSyntax Error: Expected closing ')' at position {d}\n", .{self.pos});
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

            // Right-associative operators use same power, left-associative use power + 1
            const nextMinPower = if (isRightAssociative(op)) power else power + 1;
            const right = try self.parseExpression(nextMinPower);

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
