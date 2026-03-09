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
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    null_val: void,
};

pub const NodeData = union(enum) { literal: LiteralValue, variable: []const u8, binary: struct {
    op: TokenType,
    left: *Node,
    right: *Node,
}, assignment: struct {
    target: []const u8,
    value: *Node,
}, block: struct {
    statements: []const *Node,
}, unary: struct {
    op: TokenType,
    operand: *Node,
}, if_statement: struct {
    condition: *Node,
    then_branch: *Node,
    else_branch: ?*Node,
}, while_loop: struct {
    condition: *Node,
    body: *Node,
    prime_vars: []const []const u8,
}, prime_assignment: struct {
    target: []const u8,
    value: *Node,
} };

pub const Node = struct {
    span: Span,
    data: NodeData,
};

// ─── 2. Symbol Table ─────────────────────────────────────────

pub const DataType = enum {
    int,
    float,
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
        .kw_or => 1,
        .kw_and => 2,
        .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal => 3,
        .plus, .minus => 4,
        .star, .slash => 5,
        .caret => 6,
        else => 0,
    };
}

fn isRightAssociative(op: TokenType) bool {
    return op == .caret;
}

/// Walk `node` and collect every unique `prime_assignment` target name into `list`.
/// Stops descending into nested `while_loop` nodes — they collect their own prime_vars.
fn collectPrimeVars(node: *Node, list: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    switch (node.data) {
        .prime_assignment => |pa| {
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, pa.target)) return; // deduplicate
            }
            try list.append(allocator, pa.target);
        },
        .block => |b| {
            for (b.statements) |stmt| try collectPrimeVars(stmt, list, allocator);
        },
        .if_statement => |s| {
            try collectPrimeVars(s.then_branch, list, allocator);
            if (s.else_branch) |eb| try collectPrimeVars(eb, list, allocator);
        },
        // Nested while_loop: its prime_vars are managed by its own node — do not descend.
        else => {},
    }
}

pub const Parser = struct {
    lexer: Lexer,
    allocator: std.mem.Allocator,
    symbols: SymbolTable,
    current: Token,
    peek_token: Token,
    loop_depth: usize,
    /// Set to the offending token whenever a parse error is returned.
    error_token: Token,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) !Parser {
        var lexer = Lexer.init(input);
        const first = lexer.next();
        const second = lexer.next();
        return .{
            .lexer = lexer,
            .allocator = allocator,
            .symbols = try SymbolTable.init(allocator),
            .current = first,
            .peek_token = second,
            .loop_depth = 0,
            .error_token = .{ .token_type = .eof, .lexeme = "", .start = 0, .end = 0 },
        };
    }

    pub fn deinit(self: *Parser) void {
        self.symbols.deinit();
    }

    fn advance(self: *Parser) void {
        self.current = self.peek_token;
        self.peek_token = self.lexer.next();
    }

    /// Infer the DataType of an expression node (best-effort; defaults to .int for unknowns).
    fn inferType(self: *const Parser, node: *const Node) DataType {
        return switch (node.data) {
            .literal => |lit| switch (lit) {
                .int => .int,
                .float => .float,
                .boolean => .boolean,
                .string => .string,
                .null_val => .int,
            },
            .variable => |name| blk: {
                var i = self.symbols.scopes.items.len;
                while (i > 0) {
                    i -= 1;
                    if (self.symbols.scopes.items[i].get(name)) |t| break :blk t;
                }
                break :blk .int;
            },
            .binary => |b| blk: {
                // Comparison/logical ops always produce boolean (stored as int 0/1)
                switch (b.op) {
                    .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal, .kw_and, .kw_or => break :blk .int,
                    else => {},
                }
                // Arithmetic: float if either operand is float
                const lt = self.inferType(b.left);
                const rt = self.inferType(b.right);
                break :blk if (lt == .float or rt == .float) .float else .int;
            },
            .unary => .int, // bang produces 0/1
            .assignment => |a| self.inferType(a.value),
            .prime_assignment => |pa| self.inferType(pa.value),
            .block => .int,
            .if_statement => .int,
            .while_loop => .int,
        };
    }

    fn parseAtom(self: *Parser) anyerror!*Node {
        const token = self.current;

        if (token.token_type == .l_paren) {
            self.advance();
            const expr = try self.parseExpression(0);
            if (self.current.token_type != .r_paren) {
                self.error_token = self.current;
                return error.UnmatchedParenthesis;
            }

            // Expand the span to include the parentheses
            expr.span.start = token.start;
            expr.span.end = self.current.end;

            self.advance(); // consume ')'
            return expr;
        }

        if (token.token_type == .identifier) {
            if (!self.symbols.isDefined(token.lexeme)) {
                self.error_token = token;
                return error.UndefinedVariable;
            }

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
            // Determine if this is an integer or float literal
            const is_float = std.mem.indexOfScalar(u8, token.lexeme, '.') != null;
            const lit: LiteralValue = if (is_float)
                .{ .float = try std.fmt.parseFloat(f64, token.lexeme) }
            else
                .{ .int = try std.fmt.parseInt(i64, token.lexeme, 10) };
            node.* = .{
                .span = .{ .start = token.start, .end = token.end },
                .data = .{ .literal = lit },
            };
            self.advance();
            return node;
        }

        if (token.token_type == .kw_true or token.token_type == .kw_false) {
            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = token.end },
                .data = .{ .literal = .{ .boolean = token.token_type == .kw_true } },
            };
            self.advance();
            return node;
        }

        if (token.token_type == .bang) {
            self.advance(); // consume '!'
            const operand = try self.parseAtom();
            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = operand.span.end },
                .data = .{ .unary = .{ .op = .bang, .operand = operand } },
            };
            return node;
        }

        self.error_token = self.current;
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
            const val_type = self.inferType(value);
            try self.symbols.define(target_token.lexeme, val_type);

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = target_token.start, .end = value.span.end },
                .data = .{ .assignment = .{ .target = target_token.lexeme, .value = value } },
            };

            if (self.current.token_type == .newline) self.advance();
            return node;
        }

        if (self.current.token_type == .identifier and self.peek_token.token_type == .prime) {
            const target_token = self.current;
            self.advance(); // consume identifier
            self.advance(); // consume '`'

            if (self.loop_depth == 0) {
                self.error_token = target_token;
                return error.PrimeOutsideLoop;
            }
            if (self.symbols.isDefined(target_token.lexeme) == false) {
                self.error_token = target_token;
                return error.UndefinedVariable;
            }

            if (self.current.token_type == .equal) {
                self.advance(); // consume '='
            } else {
                self.error_token = self.current;
                return error.ExpectedEqualAfterPrime;
            }

            const value = try self.parseExpression(0);

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = target_token.start, .end = value.span.end },
                .data = .{ .prime_assignment = .{ .target = target_token.lexeme, .value = value } },
            };

            if (self.current.token_type == .newline) self.advance();
            return node;
        }

        if (self.current.token_type == .kw_if) {
            const token_start = self.current.start;
            self.advance(); // consume 'if'

            if (self.current.token_type != .l_paren) return error.ExpectedIfCondition;
            self.advance(); // consume '('
            const condition = try self.parseExpression(0);
            if (self.current.token_type != .r_paren) return error.UnmatchedParenthesis;
            self.advance(); // consume ')'

            // --- Branches ---
            const then_branch = try self.parseStatement() orelse return error.ExpectedThenStatement;

            var else_branch: ?*Node = null;
            var end_pos = then_branch.span.end;

            if (self.current.token_type == .kw_else) {
                self.advance(); // consume 'else'
                const else_stmt = try self.parseStatement() orelse return error.ExpectedElseStatement;
                else_branch = else_stmt;
                end_pos = else_stmt.span.end; // Update the end position
            }

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token_start, .end = end_pos },
                .data = .{
                    .if_statement = .{
                        .condition = condition,
                        .then_branch = then_branch,
                        .else_branch = else_branch,
                    },
                },
            };
            return node;
        }

        if (self.current.token_type == .kw_while) {
            const token_start = self.current.start;
            self.advance(); // consume 'while'

            if (self.current.token_type != .l_paren) return error.ExpectedWhileCondition;
            self.advance(); // consume '('
            const condition = try self.parseExpression(0);
            if (self.current.token_type != .r_paren) return error.UnmatchedParenthesis;
            self.advance(); // consume ')'
            self.loop_depth += 1;
            const body = try self.parseStatement() orelse return error.ExpectedWhileBody;
            self.loop_depth -= 1;

            var prime_var_list: std.ArrayList([]const u8) = .empty;
            try collectPrimeVars(body, &prime_var_list, self.allocator);
            const prime_vars = try prime_var_list.toOwnedSlice(self.allocator);

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token_start, .end = body.span.end },
                .data = .{
                    .while_loop = .{
                        .condition = condition,
                        .body = body,
                        .prime_vars = prime_vars,
                    },
                },
            };
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
    const root = parser.parseProgram() catch |err| {
        // Walk the input to find line/column of the offending token
        const tok = parser.error_token;
        var line: usize = 1;
        var col: usize = 1;
        for (input[0..@min(tok.start, input.len)]) |c| {
            if (c == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }
        }
        const lexeme = if (tok.lexeme.len > 0) tok.lexeme else "<end of input>";
        std.debug.print(
            "\nParse error [{s}] at line {d}, col {d}: '{s}'\n",
            .{ @errorName(err), line, col, lexeme },
        );
        return err;
    };

    // 4. Return the AST struct containing both the root node AND the arena holding its memory.
    return ParsedAst{
        .arena = arena,
        .root = root,
    };
}
