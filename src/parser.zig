const std = @import("std");
const lexer_module = @import("lexer.zig");
const Lexer = lexer_module.Lexer;
const Token = lexer_module.Token;
const TokenType = lexer_module.TokenType;

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const LiteralValue = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
    null_val: void,
};

pub const NodeData = union(enum) {
    literal: LiteralValue,
    variable: []const u8,

    binary: struct {
        op: TokenType,
        left: *Node,
        right: *Node,
    },

    assignment: struct {
        target: []const u8,
        value: *Node,
    },

    block: struct {
        statements: []const *Node,
    },

    // Ready for you to implement later!
    if_statement: struct {
        condition: *Node,
        then_branch: *Node,
        else_branch: ?*Node,
    },
};

pub const Node = struct {
    span: Span,
    data: NodeData,
};

// ─── 2. Symbol Table ─────────────────────────────────────────

pub const DataType = enum {
    number,
    boolean,
    string,
};

pub const SymbolTable = struct {
    scopes: std.ArrayList(std.StringHashMap(DataType)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !SymbolTable {
        var st = SymbolTable{ .scopes = .empty, .allocator = allocator };
        try st.scopes.append(allocator, std.StringHashMap(DataType).init(allocator));
        return st;
    }

    pub fn deinit(self: *SymbolTable) void {
        for (self.scopes.items) |*scope| scope.deinit();
        self.scopes.deinit(self.allocator);
    }

    pub fn pushScope(self: *SymbolTable) !void {
        try self.scopes.append(self.allocator, std.StringHashMap(DataType).init(self.allocator));
    }

    pub fn popScope(self: *SymbolTable) void {
        if (self.scopes.items.len > 1) {
            var scope = self.scopes.pop().?;
            scope.deinit();
        }
    }

    pub fn define(self: *SymbolTable, name: []const u8, val_type: DataType) !void {
        const idx = self.scopes.items.len - 1;
        if (self.scopes.items[idx].get(name) != null) return error.VariableAlreadyDefined;
        try self.scopes.items[idx].put(name, val_type);
    }

    pub fn isDefined(self: *const SymbolTable, name: []const u8) bool {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name) != null) return true;
        }
        return false;
    }
};

// ─── 3. Parser ───────────────────────────────────────────────

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

pub const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    symbols: SymbolTable,
    current: Token,
    peek_token: Token,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) !Parser {
        var lexer = Lexer.init(input);
        return .{
            .lexer = lexer,
            .allocator = allocator,
            .symbols = try SymbolTable.init(allocator),
            .current = lexer.next(),
            .peek_token = lexer.next(),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.symbols.deinit();
    }

    fn advance(self: *Parser) void {
        self.current = self.peek_token;
        self.peek_token = self.lexer.next();
    }

    fn parseAtom(self: *Parser) anyerror!*Node {
        const token = self.current;

        if (token.token_type == .l_paren) {
            self.advance();
            const expr = try self.parseExpression(0);
            if (self.current.token_type != .r_paren) return error.UnmatchedParenthesis;

            // Expand the span to include the parentheses
            expr.span.start = token.start;
            expr.span.end = self.current.end;

            self.advance(); // consume ')'
            return expr;
        }

        if (token.token_type == .identifier) {
            if (!self.symbols.isDefined(token.lexeme)) return error.UndefinedVariable;

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = token.end },
                .data = .{ .variable = token.lexeme },
            };
            self.advance();
            return node;
        }

        if (token.token_type == .number) {
            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = token.end },
                .data = .{ .literal = .{ .number = try std.fmt.parseFloat(f64, token.lexeme) } },
            };
            self.advance();
            return node;
        }

        return error.UnexpectedToken;
    }

    fn parseExpression(self: *Parser, minPower: usize) anyerror!*Node {
        var left = try self.parseAtom();

        while (true) {
            const op_type = self.current.token_type;
            if (op_type == .newline or op_type == .r_paren or op_type == .r_brace or op_type == .eof) break;

            const power = getBindingPower(op_type);
            if (power == 0 or power < minPower) break;

            self.advance(); // consume operator

            const nextMinPower = if (isRightAssociative(op_type)) power else power + 1;
            const right = try self.parseExpression(nextMinPower);

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = left.span.start, .end = right.span.end }, // Dynamic span calculation!
                .data = .{ .binary = .{ .op = op_type, .left = left, .right = right } },
            };
            left = node;
        }

        return left;
    }

    fn parseStatement(self: *Parser) anyerror!?*Node {
        while (self.current.token_type == .newline) self.advance();
        if (self.current.token_type == .eof) return null;

        if (self.current.token_type == .l_brace) return try self.parseBlock();

        if (self.current.token_type == .identifier and self.peek_token.token_type == .equal) {
            const target_token = self.current;
            self.advance(); // consume identifier
            self.advance(); // consume '='

            const value = try self.parseExpression(0);
            try self.symbols.define(target_token.lexeme, .number);

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = target_token.start, .end = value.span.end },
                .data = .{ .assignment = .{ .target = target_token.lexeme, .value = value } },
            };

            if (self.current.token_type == .newline) self.advance();
            return node;
        }

        const expr = try self.parseExpression(0);
        if (self.current.token_type == .newline) self.advance();
        return expr;
    }

    fn parseBlock(self: *Parser) anyerror!*Node {
        const start_pos = self.current.start;
        self.advance(); // consume '{'
        try self.symbols.pushScope();

        var stmts: std.ArrayList(*Node) = .empty;

        while (true) {
            while (self.current.token_type == .newline) self.advance();
            if (self.current.token_type == .eof) return error.ExpectedClosingBrace;

            if (self.current.token_type == .r_brace) {
                break;
            }

            if (try self.parseStatement()) |stmt| {
                try stmts.append(self.allocator, stmt);
            }
        }

        const end_pos = self.current.end;
        self.advance(); // consume '}'
        self.symbols.popScope();

        const node = try self.allocator.create(Node);
        node.* = .{
            .span = .{ .start = start_pos, .end = end_pos },
            .data = .{ .block = .{ .statements = try stmts.toOwnedSlice(self.allocator) } },
        };
        return node;
    }

    pub fn parseProgram(self: *Parser) !*Node {
        var stmts: std.ArrayList(*Node) = .empty;

        while (true) {
            if (try self.parseStatement()) |stmt| {
                try stmts.append(self.allocator, stmt);
            } else {
                break;
            }
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .span = .{ .start = 0, .end = self.current.end },
            .data = .{ .block = .{ .statements = try stmts.toOwnedSlice(self.allocator) } },
        };
        return node;
    }
};

// ─── 4. Public API with Arena Allocator ──────────────────────

// Wraps the parsed root and the arena that holds it.
pub const ParsedAst = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,

    // The user of this library only needs to call this once
    // to free the entire syntax tree.
    pub fn deinit(self: *ParsedAst) void {
        self.arena.deinit();
    }
};

pub fn programParse(input: []const u8, backing_allocator: std.mem.Allocator) !ParsedAst {
    // 1. Create an Arena Allocator wrapping the standard allocator.
    var arena = std.heap.ArenaAllocator.init(backing_allocator);

    // If parsing fails midway, cleanly destroy the arena before returning the error.
    errdefer arena.deinit();

    // 2. Get the arena's allocator interface.
    // Every node, string slice, and array created using this allocator will live inside the arena.
    const arena_alloc = arena.allocator();

    var parser = try Parser.init(input, arena_alloc);
    defer parser.deinit(); // Cleans up the SymbolTable's internal structures

    // 3. Parse the entire syntax tree.
    const root = try parser.parseProgram();

    // 4. Return the AST struct containing both the root node AND the arena holding its memory.
    return ParsedAst{
        .arena = arena,
        .root = root,
    };
}
