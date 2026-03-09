const std = @import("std");
const lexer_module = @import("lexer.zig");
const Lexer = lexer_module.Lexer;
const Token = lexer_module.Token;
const TokenType = lexer_module.TokenType;

// ─── Node Types (Tagged Union) ───────────────────────────────

pub const Node = union(enum) {
    number: f32,
    variable: []const u8,
    binary_op: struct {
        operator: TokenType,
        left: *Node,
        right: *Node,
    },
    assignment: struct {
        name: []const u8,
        value: *Node,
    },
    block: struct {
        statements: []const *Node,
    },
};

// ─── Binding Power (Pratt Parser) ────────────────────────────

fn getBindingPower(op: TokenType) usize {
    return switch (op) {
        .plus, .minus => 1,
        .star, .slash => 2,
        .caret => 3,
        else => 0,
    };
}

fn isRightAssociative(op: TokenType) bool {
    return op == .caret;
}

// ─── Symbol Table ────────────────────────────────────────────

// We now map names to a ValueType, preparing the environment for booleans.
pub const ValueType = enum {
    number,
    boolean, // Added for future boolean support
};

pub const SymbolTable = struct {
    scopes: std.ArrayList(std.StringHashMap(ValueType)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !SymbolTable {
        var st = SymbolTable{
            .scopes = .empty, // <-- Initialize as .empty
            .allocator = allocator,
        };
        // Pass allocator to append
        try st.scopes.append(allocator, std.StringHashMap(ValueType).init(allocator));
        return st;
    }

    pub fn deinit(self: *SymbolTable) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        // Pass allocator to deinit
        self.scopes.deinit(self.allocator);
    }

    pub fn pushScope(self: *SymbolTable) !void {
        // Pass allocator to append
        try self.scopes.append(self.allocator, std.StringHashMap(ValueType).init(self.allocator));
    }
    pub fn popScope(self: *SymbolTable) void {
        if (self.scopes.items.len > 1) {
            // Restore the .? because pop() returns an optional in Zig 0.14/0.15
            var scope = self.scopes.pop().?;
            scope.deinit();
        }
    }

    pub fn define(self: *SymbolTable, name: []const u8, val_type: ValueType) !void {
        const idx = self.scopes.items.len - 1;
        if (self.scopes.items[idx].get(name) != null) {
            return error.VariableAlreadyDefined;
        }
        try self.scopes.items[idx].put(name, val_type);
    }

    pub fn getType(self: *const SymbolTable, name: []const u8) ?ValueType {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |val_type| {
                return val_type;
            }
        }
        return null;
    }

    pub fn isDefined(self: *const SymbolTable, name: []const u8) bool {
        return self.getType(name) != null;
    }
};

// ─── Parser ──────────────────────────────────────────────────

pub const ParseError = std.mem.Allocator.Error || std.fmt.ParseFloatError || error{
    UnmatchedParenthesis,
    UnexpectedToken,
    UndefinedVariable,
    VariableAlreadyDefined,
    ExpectedNewline,
    ExpectedClosingBrace,
    InvalidNumber,
};

pub const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    symbols: SymbolTable,

    // We keep track of the current token and the next token (peek).
    // Peeking helps us distinguish between an identifier expression and an assignment.
    current: Token,
    peek_token: Token,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) !Parser {
        var lexer = Lexer.init(input);
        const current = lexer.next();
        const peek_token = lexer.next();

        return .{
            .lexer = lexer,
            .allocator = allocator,
            .symbols = try SymbolTable.init(allocator),
            .current = current,
            .peek_token = peek_token,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.symbols.deinit();
    }

    /// Advance the token stream by one
    fn advance(self: *Parser) void {
        self.current = self.peek_token;
        self.peek_token = self.lexer.next();
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        const token = self.current;

        if (token.token_type == .l_paren) {
            self.advance(); // consume '('
            const expr = try self.parseExpression(0);

            if (self.current.token_type != .r_paren) {
                std.debug.print("\nSyntax Error: Expected closing ')'\n", .{});
                return error.UnmatchedParenthesis;
            }
            self.advance(); // consume ')'
            return expr;
        }

        if (token.token_type == .identifier) {
            if (!self.symbols.isDefined(token.lexeme)) {
                std.debug.print("\nError: Undefined variable '{s}'\n", .{token.lexeme});
                return error.UndefinedVariable;
            }

            const node = try self.allocator.create(Node);
            node.* = .{ .variable = token.lexeme };
            self.advance();
            return node;
        }

        if (token.token_type == .number) {
            const node = try self.allocator.create(Node);
            node.* = .{
                .number = std.fmt.parseFloat(f32, token.lexeme) catch |err| {
                    std.debug.print("\nSyntax Error: Invalid number format '{s}'\n", .{token.lexeme});
                    return err;
                },
            };
            self.advance();
            return node;
        }

        std.debug.print("\nSyntax Error: Unexpected token '{s}'\n", .{token.lexeme});
        return error.UnexpectedToken;
    }

    fn parseExpression(self: *Parser, minPower: usize) ParseError!*Node {
        var left = try self.parseAtom();

        while (true) {
            const op_type = self.current.token_type;

            // Stop at statement boundaries or EOF
            if (op_type == .newline or op_type == .r_paren or op_type == .r_brace or op_type == .eof) break;

            const power = getBindingPower(op_type);
            if (power == 0 or power < minPower) break;

            self.advance(); // consume operator

            const nextMinPower = if (isRightAssociative(op_type)) power else power + 1;
            const right = try self.parseExpression(nextMinPower);

            const node = try self.allocator.create(Node);
            node.* = .{ .binary_op = .{
                .operator = op_type,
                .left = left,
                .right = right,
            } };
            left = node;
        }

        return left;
    }

    fn parseStatement(self: *Parser) ParseError!?*Node {
        // Skip blank lines
        while (self.current.token_type == .newline) self.advance();

        if (self.current.token_type == .eof) return null;

        // ── Block: { ... } ──
        if (self.current.token_type == .l_brace) {
            return try self.parseBlock();
        }

        // ── Assignment: IDENTIFIER = expression ──
        // With tokens, lookahead becomes trivial! No more string backtracking.
        if (self.current.token_type == .identifier and self.peek_token.token_type == .equal) {
            const name = self.current.lexeme;
            self.advance(); // consume identifier
            self.advance(); // consume '='

            const value = try self.parseExpression(0);

            // Register in symbol table. Defaulting to number type for now.
            // When boolean is added, you can check value's type here before assigning.
            self.symbols.define(name, .number) catch |err| {
                if (err == error.VariableAlreadyDefined) {
                    std.debug.print("\nError: Variable '{s}' is already defined.\n", .{name});
                }
                return err;
            };

            const node = try self.allocator.create(Node);
            node.* = .{ .assignment = .{
                .name = name,
                .value = value,
            } };

            if (self.current.token_type != .newline and self.current.token_type != .r_brace and self.current.token_type != .eof) {
                return error.ExpectedNewline;
            }
            if (self.current.token_type == .newline) self.advance();

            return node;
        }

        // ── Expression statement ──
        const expr = try self.parseExpression(0);

        if (self.current.token_type != .newline and self.current.token_type != .r_brace and self.current.token_type != .eof) {
            std.debug.print("\nSyntax Error: Expected newline after statement.\n", .{});
            return error.ExpectedNewline;
        }
        if (self.current.token_type == .newline) self.advance();

        return expr;
    }

    fn parseBlock(self: *Parser) ParseError!*Node {
        self.advance(); // consume '{'
        try self.symbols.pushScope();

        // Initialize as .empty
        var stmts: std.ArrayList(*Node) = .empty;

        while (true) {
            while (self.current.token_type == .newline) self.advance();

            if (self.current.token_type == .eof) {
                return error.ExpectedClosingBrace;
            }

            if (self.current.token_type == .r_brace) {
                self.advance(); // consume '}'
                break;
            }

            if (try self.parseStatement()) |stmt| {
                // Pass allocator to append
                try stmts.append(self.allocator, stmt);
            }
        }

        self.symbols.popScope();

        const node = try self.allocator.create(Node);
        node.* = .{
            .block = .{
                // Pass allocator to toOwnedSlice
                .statements = try stmts.toOwnedSlice(self.allocator),
            },
        };
        return node;
    }

    pub fn parseProgram(self: *Parser) !*Node {
        // Initialize as .empty
        var stmts: std.ArrayList(*Node) = .empty;

        while (true) {
            if (try self.parseStatement()) |stmt| {
                // Pass allocator to append
                try stmts.append(self.allocator, stmt);
            } else {
                break;
            }
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .block = .{
                // Pass allocator to toOwnedSlice
                .statements = try stmts.toOwnedSlice(self.allocator),
            },
        };
        return node;
    }
};

// ─── Public API ──────────────────────────────────────────────

pub fn programParse(str: []const u8, allocator: std.mem.Allocator) !*Node {
    var parser = try Parser.init(str, allocator);
    // The symbol table and internal states are only needed during parsing.
    // The AST nodes just hold references to slices of the input string.
    defer parser.deinit();

    return parser.parseProgram();
}
