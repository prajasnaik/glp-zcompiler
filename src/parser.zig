const std = @import("std");

// ─── Node Types ──────────────────────────────────────────────

pub const NodeType = enum {
    number, // numeric literal
    variable, // variable reference
    binary_op, // binary operation (+, -, *, /, ^)
    assignment, // name = expression
    block, // { statements... } or program-level statement list
};

pub const Node = struct {
    node_type: NodeType,
    operator: ?u8 = null, // binary_op: the operator character
    operand: ?f32 = null, // number: the numeric value
    name: ?[]const u8 = null, // variable / assignment: identifier name
    left: ?*Node = null, // binary_op: left operand; assignment: value expression
    right: ?*Node = null, // binary_op: right operand
    statements: ?[]*Node = null, // block: list of child statements
};

// ─── Binding Power (Pratt Parser) ────────────────────────────

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
    return op == '^';
}

// ─── Symbol Table ────────────────────────────────────────────
//
// A stack of scopes. Each scope is a string set of defined variable names.
// - Variables are immutable: once assigned, they cannot be reassigned
//   within the same scope.
// - Inner scopes may shadow outer definitions (that creates a new binding).
// - Lookup walks from innermost scope outward.

pub const SymbolTable = struct {
    scopes: std.ArrayList(std.StringHashMap(void)),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !SymbolTable {
        var st = SymbolTable{
            .scopes = .empty,
            .allocator = allocator,
        };
        // Push the global (outermost) scope
        try st.scopes.append(allocator, std.StringHashMap(void).init(allocator));
        return st;
    }

    pub fn deinit(self: *SymbolTable) void {
        for (self.scopes.items) |*scope| {
            scope.deinit();
        }
        self.scopes.deinit(self.allocator);
    }

    pub fn pushScope(self: *SymbolTable) !void {
        try self.scopes.append(self.allocator, std.StringHashMap(void).init(self.allocator));
    }

    pub fn popScope(self: *SymbolTable) void {
        if (self.scopes.items.len > 1) {
            var scope = self.scopes.pop().?;
            scope.deinit();
        }
    }

    /// Define a variable in the current (innermost) scope.
    /// Returns error.VariableAlreadyDefined if it already exists in this scope.
    pub fn define(self: *SymbolTable, name: []const u8) !void {
        const idx = self.scopes.items.len - 1;
        if (self.scopes.items[idx].get(name) != null) {
            return error.VariableAlreadyDefined;
        }
        try self.scopes.items[idx].put(name, {});
    }

    /// Look up a variable from the innermost scope outward.
    pub fn isDefined(self: *const SymbolTable, name: []const u8) bool {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name) != null) {
                return true;
            }
        }
        return false;
    }

    pub fn depth(self: *const SymbolTable) usize {
        return self.scopes.items.len;
    }
};

// ─── Parser ──────────────────────────────────────────────────

pub const Parser = struct {
    input: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,
    symbols: SymbolTable,

    pub fn init(input: []const u8, allocator: std.mem.Allocator) !Parser {
        return .{
            .input = input,
            .pos = 0,
            .allocator = allocator,
            .symbols = try SymbolTable.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.symbols.deinit();
    }

    /// Skip horizontal whitespace only (spaces and tabs).
    /// Newlines are significant as statement terminators.
    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.input.len and
            (self.input[self.pos] == ' ' or self.input[self.pos] == '\t'))
        {
            self.pos += 1;
        }
    }

    /// Skip all whitespace including newlines.
    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.input.len and
            (self.input[self.pos] == ' ' or self.input[self.pos] == '\t' or
                self.input[self.pos] == '\n' or self.input[self.pos] == '\r'))
        {
            self.pos += 1;
        }
    }

    fn peek(self: *Parser) ?u8 {
        self.skipSpaces();
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

    fn isAlpha(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
    }

    fn isAlnum(ch: u8) bool {
        return isAlpha(ch) or (ch >= '0' and ch <= '9');
    }

    /// Parse an identifier (starts with letter/_, followed by alphanumerics).
    fn parseIdentifier(self: *Parser) ?[]const u8 {
        self.skipSpaces();
        if (self.pos >= self.input.len or !isAlpha(self.input[self.pos])) {
            return null;
        }
        const start = self.pos;
        while (self.pos < self.input.len and isAlnum(self.input[self.pos])) {
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    /// Parse a numeric literal.
    fn parseNumber(self: *Parser) !*Node {
        self.skipSpaces();
        const start = self.pos;

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
            .node_type = .number,
            .operand = std.fmt.parseFloat(f32, numStr) catch |err| {
                std.debug.print("\nSyntax Error: Invalid number format '{s}' at position {d}\n", .{ numStr, start });
                return err;
            },
        };
        return node;
    }

    /// Parse an atom: number, variable reference, or parenthesized expression.
    fn parseAtom(self: *Parser) ParseError!*Node {
        self.skipSpaces();

        if (self.pos >= self.input.len) {
            std.debug.print("\nSyntax Error: Unexpected end of input at position {d}\n", .{self.pos});
            return error.UnexpectedCharacter;
        }

        const ch = self.input[self.pos];

        // Parenthesized expression
        if (ch == '(') {
            self.pos += 1;
            const expr = try self.parseExpression(0);
            self.skipSpaces();
            if (self.pos >= self.input.len or self.input[self.pos] != ')') {
                std.debug.print("\nSyntax Error: Expected closing ')' at position {d}\n", .{self.pos});
                return error.UnmatchedParenthesis;
            }
            self.pos += 1;
            return expr;
        }

        // Identifier (variable reference in an expression)
        if (isAlpha(ch)) {
            const start = self.pos;
            const name = self.parseIdentifier().?;

            if (!self.symbols.isDefined(name)) {
                std.debug.print("\nError: Undefined variable '{s}' at position {d}\n", .{ name, start });
                return error.UndefinedVariable;
            }

            const node = try self.allocator.create(Node);
            node.* = .{
                .node_type = .variable,
                .name = name,
            };
            return node;
        }

        // Number
        if ((ch >= '0' and ch <= '9') or ch == '.') {
            return self.parseNumber();
        }

        std.debug.print("\nSyntax Error: Unexpected character '{c}' at position {d}\n", .{ ch, self.pos });
        return error.UnexpectedCharacter;
    }

    /// Pratt parser for expressions.
    /// Stops at newlines, closing parens/braces, and non-operator characters.
    fn parseExpression(self: *Parser, minPower: usize) ParseError!*Node {
        var left = try self.parseAtom();

        while (true) {
            self.skipSpaces();
            if (self.pos >= self.input.len) break;

            const op = self.input[self.pos];
            // Stop at statement / grouping boundaries
            if (op == '\n' or op == '\r' or op == ')' or op == '}') break;

            const power = getBindingPower(op);
            if (power == 0 or power < minPower) break;

            self.pos += 1; // consume operator

            const nextMinPower = if (isRightAssociative(op)) power else power + 1;
            const right = try self.parseExpression(nextMinPower);

            const node = try self.allocator.create(Node);
            node.* = .{
                .node_type = .binary_op,
                .operator = op,
                .left = left,
                .right = right,
            };
            left = node;
        }

        return left;
    }

    /// Consume a newline sequence (\r\n, \r, or \n).
    fn consumeNewline(self: *Parser) void {
        if (self.pos < self.input.len and self.input[self.pos] == '\r') {
            self.pos += 1;
        }
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
        }
    }

    const ParseError = std.mem.Allocator.Error || std.fmt.ParseFloatError || error{
        UnmatchedParenthesis,
        UnexpectedCharacter,
        UndefinedVariable,
        VariableAlreadyDefined,
        ExpectedNewline,
        ExpectedClosingBrace,
    };

    /// Parse a single statement: assignment, block, or expression.
    /// Returns null when the input is exhausted.
    fn parseStatement(self: *Parser) ParseError!?*Node {
        // Skip blank lines
        while (self.pos < self.input.len and
            (self.input[self.pos] == '\n' or self.input[self.pos] == '\r'))
        {
            self.consumeNewline();
        }
        self.skipSpaces();

        if (self.pos >= self.input.len) return null;

        // ── Block: { ... } ──
        if (self.input[self.pos] == '{') {
            return try self.parseBlock();
        }

        // ── Possibly an assignment: IDENTIFIER = expression ──
        if (isAlpha(self.input[self.pos])) {
            const save_pos = self.pos;
            const name = self.parseIdentifier().?;
            self.skipSpaces();

            if (self.pos < self.input.len and self.input[self.pos] == '=') {
                self.pos += 1; // consume '='

                const value = try self.parseExpression(0);

                // Register in symbol table (errors if already defined in current scope)
                self.symbols.define(name) catch |err| {
                    if (err == error.VariableAlreadyDefined) {
                        std.debug.print(
                            "\nError: Variable '{s}' is already defined and cannot be reassigned (position {d})\n",
                            .{ name, save_pos },
                        );
                    }
                    return err;
                };

                const node = try self.allocator.create(Node);
                node.* = .{
                    .node_type = .assignment,
                    .name = name,
                    .left = value,
                };

                // Expect newline, '}', or EOF after assignment
                self.skipSpaces();
                if (self.pos < self.input.len and
                    self.input[self.pos] != '\n' and
                    self.input[self.pos] != '\r' and
                    self.input[self.pos] != '}')
                {
                    std.debug.print(
                        "\nSyntax Error: Expected newline after statement at position {d}\n",
                        .{self.pos},
                    );
                    return error.ExpectedNewline;
                }
                if (self.pos < self.input.len and
                    (self.input[self.pos] == '\n' or self.input[self.pos] == '\r'))
                {
                    self.consumeNewline();
                }

                return node;
            }

            // Not an assignment — backtrack and parse as expression statement
            self.pos = save_pos;
        }

        // ── Expression statement ──
        const expr = try self.parseExpression(0);

        self.skipSpaces();
        if (self.pos < self.input.len and
            self.input[self.pos] != '\n' and
            self.input[self.pos] != '\r' and
            self.input[self.pos] != '}')
        {
            std.debug.print(
                "\nSyntax Error: Expected newline after statement at position {d}\n",
                .{self.pos},
            );
            return error.ExpectedNewline;
        }
        if (self.pos < self.input.len and
            (self.input[self.pos] == '\n' or self.input[self.pos] == '\r'))
        {
            self.consumeNewline();
        }

        return expr;
    }

    /// Parse a block: { statement* }
    fn parseBlock(self: *Parser) ParseError!*Node {
        self.pos += 1; // consume '{'
        try self.symbols.pushScope();

        var stmts: std.ArrayList(*Node) = .empty;

        while (true) {
            self.skipWhitespace();

            if (self.pos >= self.input.len) {
                std.debug.print(
                    "\nSyntax Error: Expected '}}' to close block at position {d}\n",
                    .{self.pos},
                );
                return error.ExpectedClosingBrace;
            }

            if (self.input[self.pos] == '}') {
                self.pos += 1;
                break;
            }

            if (try self.parseStatement()) |stmt| {
                try stmts.append(self.allocator, stmt);
            }
        }

        self.symbols.popScope();

        const node = try self.allocator.create(Node);
        node.* = .{
            .node_type = .block,
            .statements = try stmts.toOwnedSlice(self.allocator),
        };
        return node;
    }

    /// Parse a full program (sequence of newline-separated statements).
    pub fn parseProgram(self: *Parser) !*Node {
        std.debug.print("[parser] parseProgram: input length={d}\n", .{self.input.len});
        var stmts: std.ArrayList(*Node) = .empty;
        var stmt_count: usize = 0;

        while (true) {
            std.debug.print("[parser] parseProgram: trying statement at pos={d}/{d}\n", .{ self.pos, self.input.len });
            if (try self.parseStatement()) |stmt| {
                stmt_count += 1;
                std.debug.print("[parser] parseProgram: got statement #{d}, type={s}\n", .{ stmt_count, @tagName(stmt.node_type) });
                switch (stmt.node_type) {
                    .assignment => std.debug.print("[parser]   assignment: '{s}' = <expr>\n", .{stmt.name orelse "<null>"}),
                    .number => std.debug.print("[parser]   number: {d}\n", .{stmt.operand orelse 0}),
                    .variable => std.debug.print("[parser]   variable: '{s}'\n", .{stmt.name orelse "<null>"}),
                    .binary_op => std.debug.print("[parser]   binary_op: operator='{c}'\n", .{stmt.operator orelse '?'}),
                    .block => std.debug.print("[parser]   block: {d} statements\n", .{if (stmt.statements) |s| s.len else 0}),
                }
                try stmts.append(self.allocator, stmt);
            } else {
                std.debug.print("[parser] parseProgram: no more statements (pos={d})\n", .{self.pos});
                break;
            }
        }

        std.debug.print("[parser] parseProgram: finished with {d} statement(s)\n", .{stmt_count});

        const node = try self.allocator.create(Node);
        node.* = .{
            .node_type = .block,
            .statements = try stmts.toOwnedSlice(self.allocator),
        };
        return node;
    }
};

// ─── Public API ──────────────────────────────────────────────

/// Parse a single arithmetic expression (backward compatible).
pub fn arithmeticParse(str: []const u8, allocator: std.mem.Allocator) !*Node {
    var parser = try Parser.init(str, allocator);
    return parser.parseExpression(0);
}

/// Parse a full program with statements, scoping, and symbol-table checks.
pub fn programParse(str: []const u8, allocator: std.mem.Allocator) !*Node {
    var parser = try Parser.init(str, allocator);
    return parser.parseProgram();
}
