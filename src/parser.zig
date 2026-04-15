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

pub const NodeData = union(enum) { literal: LiteralValue, variable: struct {
    name: []const u8,
    data_type: DataType,
}, binary: struct {
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
}, call: struct {
    name: []const u8,
    args: []const *Node,
}, index: struct {
    target: *Node,
    index: *Node,
}, slice: struct {
    target: *Node,
    start: ?*Node,
    end: ?*Node,
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
/// Collects prime variables at the current loop level.
/// Enforces that:
/// 1. A variable can only be primed once at this loop level
/// 2. A variable primed in a nested loop cannot be primed again in this loop
fn collectPrimeVars(
    node: *Node,
    list: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    nested_primed: *std.StringHashMap(void),
) !void {
    switch (node.data) {
        .prime_assignment => |pa| {
            // Check if already primed at this level
            for (list.items) |existing| {
                if (std.mem.eql(u8, existing, pa.target)) {
                    return error.VariableAlreadyPrimed;
                }
            }
            // Check if already primed in a nested loop
            if (nested_primed.contains(pa.target)) {
                return error.VariablePrimedInNestedLoop;
            }
            try list.append(allocator, pa.target);
        },
        .block => |b| {
            for (b.statements) |stmt| {
                try collectPrimeVars(stmt, list, allocator, nested_primed);
            }
        },
        .if_statement => |s| {
            try collectPrimeVars(s.then_branch, list, allocator, nested_primed);
            if (s.else_branch) |eb| {
                try collectPrimeVars(eb, list, allocator, nested_primed);
            }
        },
        // Track primed variables from nested while_loop
        .while_loop => |wl| {
            for (wl.prime_vars) |pv| {
                // If already primed in this loop body, nested loop cannot prime it.
                for (list.items) |existing| {
                    if (std.mem.eql(u8, existing, pv)) {
                        return error.VariablePrimedInNestedLoop;
                    }
                }
                // If a previous nested loop already primed this variable, reject.
                if (nested_primed.contains(pv)) {
                    return error.VariablePrimedInNestedLoop;
                }
                try nested_primed.put(pv, {});
            }
        },
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
                break :blk name.data_type;
            },
            .binary => |b| blk: {
                // Comparison/logical ops always produce boolean (stored as int 0/1)
                switch (b.op) {
                    .equal_equal, .not_equal, .lt, .gt, .lt_equal, .gt_equal, .kw_and, .kw_or => break :blk .int,
                    .plus => {
                        const lt = self.inferType(b.left);
                        const rt = self.inferType(b.right);
                        if (lt == .string or rt == .string) break :blk .string;
                    },
                    else => {},
                }
                // Arithmetic: float if either operand is float
                const lt = self.inferType(b.left);
                const rt = self.inferType(b.right);
                break :blk if (lt == .float or rt == .float) .float else .int;
            },
            .unary => |u| switch (u.op) {
                .bang => .int, // bang produces 0/1
                .minus => self.inferType(u.operand),
                else => .int,
            },
            .assignment => |a| self.inferType(a.value),
            .prime_assignment => |pa| self.inferType(pa.value),
            .call => |c| {
                if (std.mem.eql(u8, c.name, "find")) return .int;
                if (std.mem.eql(u8, c.name, "print")) return .int;
                return .int;
            },
            .index => .string,
            .slice => .string,
            .block => .int,
            .if_statement => .int,
            .while_loop => .int,
        };
    }

    fn parseCall(self: *Parser, ident_token: Token) anyerror!*Node {
        const call_start = ident_token.start;
        self.advance(); // consume identifier
        self.advance(); // consume '('

        var args: std.ArrayList(*Node) = .empty;
        if (self.current.token_type != .r_paren) {
            while (true) {
                const arg = try self.parseExpression(0);
                try args.append(self.allocator, arg);
                if (self.current.token_type == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
        }

        if (self.current.token_type != .r_paren) {
            self.error_token = self.current;
            return error.UnmatchedParenthesis;
        }
        const end_pos = self.current.end;
        self.advance(); // consume ')'

        const node = try self.allocator.create(Node);
        node.* = .{
            .span = .{ .start = call_start, .end = end_pos },
            .data = .{ .call = .{ .name = ident_token.lexeme, .args = try args.toOwnedSlice(self.allocator) } },
        };
        return node;
    }

    fn parsePostfix(self: *Parser, base_node: *Node) anyerror!*Node {
        var node = base_node;

        while (self.current.token_type == .l_bracket) {
            const bracket_start = self.current.start;
            self.advance(); // consume '['

            var start_expr: ?*Node = null;
            var end_expr: ?*Node = null;
            var is_slice = false;

            if (self.current.token_type != .colon and self.current.token_type != .r_bracket) {
                start_expr = try self.parseExpression(0);
            }

            if (self.current.token_type == .colon) {
                is_slice = true;
                self.advance(); // consume ':'
                if (self.current.token_type != .r_bracket) {
                    end_expr = try self.parseExpression(0);
                }
            }

            if (self.current.token_type != .r_bracket) {
                self.error_token = self.current;
                return error.ExpectedClosingBracket;
            }
            const end_pos = self.current.end;
            self.advance(); // consume ']'

            const next_node = try self.allocator.create(Node);
            if (is_slice) {
                next_node.* = .{
                    .span = .{ .start = bracket_start, .end = end_pos },
                    .data = .{ .slice = .{ .target = node, .start = start_expr, .end = end_expr } },
                };
            } else {
                if (start_expr == null) {
                    self.error_token = self.current;
                    return error.ExpectedIndexExpression;
                }
                next_node.* = .{
                    .span = .{ .start = bracket_start, .end = end_pos },
                    .data = .{ .index = .{ .target = node, .index = start_expr.? } },
                };
            }
            node = next_node;
        }

        return node;
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
            return self.parsePostfix(expr);
        }

        if (token.token_type == .identifier) {
            if (self.peek_token.token_type == .l_paren) {
                const call_node = try self.parseCall(token);
                return self.parsePostfix(call_node);
            }

            if (!self.symbols.isDefined(token.lexeme)) {
                self.error_token = token;
                return error.UndefinedVariable;
            }

            var i = self.symbols.scopes.items.len;
            var data_type: DataType = .int;
            while (i > 0) {
                i -= 1;
                if (self.symbols.scopes.items[i].get(token.lexeme)) |t| {
                    data_type = t;
                    break;
                }
            }

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = token.end },
                .data = .{ .variable = .{ .name = token.lexeme, .data_type = data_type } },
            };
            self.advance();
            return self.parsePostfix(node);
        }

        if (token.token_type == .string) {
            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = token.end },
                .data = .{ .literal = .{ .string = token.lexeme } },
            };
            self.advance();
            return self.parsePostfix(node);
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
            return self.parsePostfix(node);
        }

        if (token.token_type == .kw_true or token.token_type == .kw_false) {
            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = token.end },
                .data = .{ .literal = .{ .boolean = token.token_type == .kw_true } },
            };
            self.advance();
            return self.parsePostfix(node);
        }

        if (token.token_type == .bang or token.token_type == .minus) {
            const op = token.token_type;
            self.advance(); // consume unary operator
            const operand = try self.parseAtom();
            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = operand.span.end },
                .data = .{ .unary = .{ .op = op, .operand = operand } },
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
            if (op_type == .newline or op_type == .r_paren or op_type == .r_brace or op_type == .r_bracket or op_type == .comma or op_type == .colon or op_type == .eof) break;

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
            var nested_primed = std.StringHashMap(void).init(self.allocator);
            defer nested_primed.deinit();
            try collectPrimeVars(body, &prime_var_list, self.allocator, &nested_primed);
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
