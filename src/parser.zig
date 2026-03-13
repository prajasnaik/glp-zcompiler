//! Parser and AST definitions for `.dpl`.
//! Includes scoped symbol tracking and arena-backed parse output.
const std = @import("std");
const lexer_module = @import("lexer.zig");
const Lexer = lexer_module.Lexer;
const Token = lexer_module.Token;
const TokenType = lexer_module.TokenType;

/// Byte-range span in source input.
pub const Span = struct {
    start: usize,
    end: usize,
};

/// Literal payload variants in the AST.
pub const LiteralValue = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    string: []const u8,
    null_val: void,
};

pub const FunctionParam = struct {
    name: []const u8,
    ty: DataType,
};

pub const FunctionSignature = struct {
    params: []const FunctionParam,
    return_type: DataType,
};

/// AST node kinds for expressions and statements.
pub const NodeData = union(enum) { literal: LiteralValue, variable: struct {
    name: []const u8,
    ty: DataType,
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
}, function_def: struct {
    name: []const u8,
    params: []const FunctionParam,
    return_type: DataType,
    body: *Node,
}, function_call: struct {
    name: []const u8,
    args: []const *Node,
    param_types: []const DataType,
    return_type: DataType,
} };

/// A syntax tree node containing source span and node payload.
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

/// Nested lexical-scope symbol table with simple define/lookup operations.
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
        return self.isDefinedFrom(name, 0);
    }

    pub fn isDefinedFrom(self: *const SymbolTable, name: []const u8, min_scope: usize) bool {
        var i = self.scopes.items.len;
        while (i > min_scope) {
            i -= 1;
            if (self.scopes.items[i].get(name) != null) return true;
        }
        return false;
    }

    pub fn lookupTypeFrom(self: *const SymbolTable, name: []const u8, min_scope: usize) ?DataType {
        var i = self.scopes.items.len;
        while (i > min_scope) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |ty| return ty;
        }
        return null;
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

fn parseTypeName(name: []const u8) !DataType {
    if (std.mem.eql(u8, name, "int")) return .int;
    if (std.mem.eql(u8, name, "float")) return .float;
    if (std.mem.eql(u8, name, "boolean")) return .boolean;
    if (std.mem.eql(u8, name, "string")) return .string;
    return error.ExpectedTypeName;
}

fn deinitFunctionTable(functions: *std.StringHashMap(FunctionSignature)) void {
    functions.deinit();
}

fn collectFunctionSignatures(input: []const u8, allocator: std.mem.Allocator) !std.StringHashMap(FunctionSignature) {
    var functions = std.StringHashMap(FunctionSignature).init(allocator);
    errdefer deinitFunctionTable(&functions);

    var lexer = Lexer.init(input);
    var current = lexer.next();
    var brace_depth: usize = 0;

    while (current.token_type != .eof) {
        if (brace_depth == 0 and current.token_type == .kw_fn) {
            const name_token = lexer.next();
            if (name_token.token_type != .identifier) return error.ExpectedFunctionName;
            if (functions.get(name_token.lexeme) != null) return error.FunctionAlreadyDefined;

            var token = lexer.next();
            if (token.token_type != .l_paren) return error.ExpectedParameterList;

            var params: std.ArrayList(FunctionParam) = .empty;
            while (true) {
                token = lexer.next();
                if (token.token_type == .r_paren) break;
                if (token.token_type != .identifier) return error.ExpectedParameterName;
                const param_name = token.lexeme;

                token = lexer.next();
                if (token.token_type != .colon) return error.ExpectedColonAfterParameter;

                token = lexer.next();
                if (token.token_type != .identifier) return error.ExpectedTypeName;
                const param_type = try parseTypeName(token.lexeme);

                for (params.items) |existing| {
                    if (std.mem.eql(u8, existing.name, param_name)) return error.ParameterAlreadyDefined;
                }
                try params.append(allocator, .{ .name = param_name, .ty = param_type });

                token = lexer.next();
                if (token.token_type == .comma) continue;
                if (token.token_type == .r_paren) break;
                return error.ExpectedCommaOrClosingParen;
            }

            token = lexer.next();
            if (token.token_type != .arrow) return error.ExpectedArrowAfterParameters;

            token = lexer.next();
            if (token.token_type != .identifier) return error.ExpectedTypeName;
            const return_type = try parseTypeName(token.lexeme);

            token = lexer.next();
            if (token.token_type != .l_brace) return error.ExpectedFunctionBody;

            try functions.put(name_token.lexeme, .{
                .params = try params.toOwnedSlice(allocator),
                .return_type = return_type,
            });

            var function_brace_depth: usize = 1;
            while (function_brace_depth > 0) {
                token = lexer.next();
                switch (token.token_type) {
                    .l_brace => function_brace_depth += 1,
                    .r_brace => {
                        function_brace_depth -= 1;
                    },
                    .eof => return error.ExpectedClosingBrace,
                    else => {},
                }
            }

            current = lexer.next();
            continue;
        }

        switch (current.token_type) {
            .l_brace => brace_depth += 1,
            .r_brace => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            else => {},
        }

        current = lexer.next();
    }

    return functions;
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
    functions: std.StringHashMap(FunctionSignature),
    current: Token,
    peek_token: Token,
    loop_depth: usize,
    block_depth: usize,
    function_scope_min: ?usize,
    current_function_return_type: ?DataType,
    /// Set to the offending token whenever a parse error is returned.
    error_token: Token,

    /// Construct a parser with two-token lookahead.
    pub fn init(input: []const u8, allocator: std.mem.Allocator, functions: std.StringHashMap(FunctionSignature)) !Parser {
        var lexer = Lexer.init(input);
        const first = lexer.next();
        const second = lexer.next();
        return .{
            .lexer = lexer,
            .allocator = allocator,
            .symbols = try SymbolTable.init(allocator),
            .functions = functions,
            .current = first,
            .peek_token = second,
            .loop_depth = 0,
            .block_depth = 0,
            .function_scope_min = null,
            .current_function_return_type = null,
            .error_token = .{ .token_type = .eof, .lexeme = "", .start = 0, .end = 0 },
        };
    }

    /// Release parser-owned resources (symbol scopes).
    pub fn deinit(self: *Parser) void {
        self.symbols.deinit();
        self.functions.deinit();
    }

    fn advance(self: *Parser) void {
        self.current = self.peek_token;
        self.peek_token = self.lexer.next();
    }

    fn visibleScopeStart(self: *const Parser) usize {
        return self.function_scope_min orelse 0;
    }

    fn lookupVariableType(self: *const Parser, name: []const u8) ?DataType {
        return self.symbols.lookupTypeFrom(name, self.visibleScopeStart());
    }

    fn isTypeAssignable(expected: DataType, actual: DataType) bool {
        return expected == actual or (expected == .float and actual == .int);
    }

    fn valueType(self: *const Parser, node: *const Node) ?DataType {
        return switch (node.data) {
            .literal, .variable, .binary, .unary, .function_call => self.inferType(node),
            .block => |block| blk: {
                if (block.statements.len == 0) break :blk null;
                break :blk self.valueType(block.statements[block.statements.len - 1]);
            },
            .if_statement => |stmt| blk: {
                const then_ty = self.valueType(stmt.then_branch) orelse break :blk null;
                const else_node = stmt.else_branch orelse break :blk null;
                const else_ty = self.valueType(else_node) orelse break :blk null;
                if (then_ty != else_ty) break :blk null;
                break :blk then_ty;
            },
            else => null,
        };
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
            .variable => |var_ref| blk: {
                break :blk var_ref.ty;
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
            .function_call => |call| call.return_type,
            .block => .int,
            .if_statement => .int,
            .while_loop => .int,
            .function_def => .int,
        };
    }

    fn parseCall(self: *Parser, ident_token: Token) anyerror!*Node {
        const signature = self.functions.get(ident_token.lexeme) orelse {
            self.error_token = ident_token;
            return error.UndefinedFunction;
        };

        self.advance(); // consume identifier
        self.advance(); // consume '('

        var args: std.ArrayList(*Node) = .empty;
        var arg_index: usize = 0;
        while (self.current.token_type != .r_paren) {
            const arg = try self.parseExpression(0);
            if (arg_index >= signature.params.len) {
                self.error_token = ident_token;
                return error.ArgumentCountMismatch;
            }
            const arg_ty = self.inferType(arg);
            if (!isTypeAssignable(signature.params[arg_index].ty, arg_ty)) {
                self.error_token = ident_token;
                return error.ArgumentTypeMismatch;
            }
            try args.append(self.allocator, arg);
            arg_index += 1;

            if (self.current.token_type == .comma) {
                self.advance();
                continue;
            }
            if (self.current.token_type != .r_paren) {
                self.error_token = self.current;
                return error.ExpectedCommaOrClosingParen;
            }
        }

        if (arg_index != signature.params.len) {
            self.error_token = ident_token;
            return error.ArgumentCountMismatch;
        }

        const node = try self.allocator.create(Node);
        var param_types = try self.allocator.alloc(DataType, signature.params.len);
        for (signature.params, 0..) |param, i| {
            param_types[i] = param.ty;
        }
        node.* = .{
            .span = .{ .start = ident_token.start, .end = self.current.end },
            .data = .{ .function_call = .{
                .name = ident_token.lexeme,
                .args = try args.toOwnedSlice(self.allocator),
                .param_types = param_types,
                .return_type = signature.return_type,
            } },
        };
        self.advance(); // consume ')'
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
            return expr;
        }

        if (token.token_type == .identifier) {
            if (self.peek_token.token_type == .l_paren) {
                return self.parseCall(token);
            }

            const var_type = self.lookupVariableType(token.lexeme) orelse {
                self.error_token = token;
                return error.UndefinedVariable;
            };

            const node = try self.allocator.create(Node);
            node.* = .{
                .span = .{ .start = token.start, .end = token.end },
                .data = .{ .variable = .{ .name = token.lexeme, .ty = var_type } },
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

        if (self.current.token_type == .kw_fn) {
            if (self.block_depth != 0 or self.function_scope_min != null) {
                self.error_token = self.current;
                return error.FunctionMustBeTopLevel;
            }
            return try self.parseFunction();
        }

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
            if (self.lookupVariableType(target_token.lexeme) == null) {
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
        return self.parseBlockWithScope(true);
    }

    fn parseBlockWithScope(self: *Parser, create_scope: bool) anyerror!*Node {
        const start_pos = self.current.start;
        self.advance(); // consume '{'
        self.block_depth += 1;
        defer self.block_depth -= 1;

        if (create_scope) try self.symbols.pushScope();
        defer if (create_scope) self.symbols.popScope();

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

        const node = try self.allocator.create(Node);
        node.* = .{
            .span = .{ .start = start_pos, .end = end_pos },
            .data = .{ .block = .{ .statements = try stmts.toOwnedSlice(self.allocator) } },
        };
        return node;
    }

    fn parseFunction(self: *Parser) anyerror!*Node {
        const fn_token = self.current;
        self.advance(); // consume 'fn'

        if (self.current.token_type != .identifier) {
            self.error_token = self.current;
            return error.ExpectedFunctionName;
        }
        const name_token = self.current;
        self.advance();

        if (self.current.token_type != .l_paren) {
            self.error_token = self.current;
            return error.ExpectedParameterList;
        }
        self.advance(); // consume '('

        var params: std.ArrayList(FunctionParam) = .empty;
        while (self.current.token_type != .r_paren) {
            if (self.current.token_type != .identifier) {
                self.error_token = self.current;
                return error.ExpectedParameterName;
            }
            const param_name = self.current.lexeme;
            self.advance();

            if (self.current.token_type != .colon) {
                self.error_token = self.current;
                return error.ExpectedColonAfterParameter;
            }
            self.advance();

            if (self.current.token_type != .identifier) {
                self.error_token = self.current;
                return error.ExpectedTypeName;
            }
            const param_type = try parseTypeName(self.current.lexeme);
            for (params.items) |existing| {
                if (std.mem.eql(u8, existing.name, param_name)) {
                    self.error_token = self.current;
                    return error.ParameterAlreadyDefined;
                }
            }
            try params.append(self.allocator, .{ .name = param_name, .ty = param_type });
            self.advance();

            if (self.current.token_type == .comma) {
                self.advance();
                continue;
            }
            if (self.current.token_type != .r_paren) {
                self.error_token = self.current;
                return error.ExpectedCommaOrClosingParen;
            }
        }
        self.advance(); // consume ')'

        if (self.current.token_type != .arrow) {
            self.error_token = self.current;
            return error.ExpectedArrowAfterParameters;
        }
        self.advance();

        if (self.current.token_type != .identifier) {
            self.error_token = self.current;
            return error.ExpectedTypeName;
        }
        const return_type = try parseTypeName(self.current.lexeme);
        self.advance();

        if (self.current.token_type != .l_brace) {
            self.error_token = self.current;
            return error.ExpectedFunctionBody;
        }

        const signature = self.functions.get(name_token.lexeme) orelse {
            self.error_token = name_token;
            return error.UndefinedFunction;
        };
        if (signature.params.len != params.items.len or signature.return_type != return_type) {
            self.error_token = name_token;
            return error.FunctionSignatureMismatch;
        }

        try self.symbols.pushScope();
        errdefer self.symbols.popScope();

        const previous_scope_min = self.function_scope_min;
        const previous_return_type = self.current_function_return_type;
        self.function_scope_min = self.symbols.scopes.items.len - 1;
        self.current_function_return_type = return_type;
        defer {
            self.function_scope_min = previous_scope_min;
            self.current_function_return_type = previous_return_type;
        }

        for (params.items) |param| {
            try self.symbols.define(param.name, param.ty);
        }

        const body = try self.parseBlockWithScope(false);
        self.symbols.popScope();

        const body_type = self.valueType(body) orelse {
            self.error_token = name_token;
            return error.FunctionMustEndWithValue;
        };
        if (!isTypeAssignable(return_type, body_type)) {
            self.error_token = name_token;
            return error.ReturnTypeMismatch;
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .span = .{ .start = fn_token.start, .end = body.span.end },
            .data = .{ .function_def = .{
                .name = name_token.lexeme,
                .params = try params.toOwnedSlice(self.allocator),
                .return_type = return_type,
                .body = body,
            } },
        };
        return node;
    }

    /// Parse the entire input as a top-level block node.
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
    /// Free all memory allocated for this parsed AST.
    pub fn deinit(self: *ParsedAst) void {
        self.arena.deinit();
    }
};

/// Parse source text into an arena-backed AST wrapper.
pub fn programParse(input: []const u8, backing_allocator: std.mem.Allocator) !ParsedAst {
    // 1. Create an Arena Allocator wrapping the standard allocator.
    var arena = std.heap.ArenaAllocator.init(backing_allocator);

    // If parsing fails midway, cleanly destroy the arena before returning the error.
    errdefer arena.deinit();

    // 2. Get the arena's allocator interface.
    // Every node, string slice, and array created using this allocator will live inside the arena.
    const arena_alloc = arena.allocator();

    const functions = try collectFunctionSignatures(input, arena_alloc);

    var parser = try Parser.init(input, arena_alloc, functions);
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

test "parses typed function definition and call" {
    const testing = std.testing;
    const source =
        \\fn add(a: int, b: int) -> int {
        \\    a + b
        \\}
        \\add(2, 3)
    ;

    var ast = try programParse(source, testing.allocator);
    defer ast.deinit();

    try testing.expect(ast.root.data == .block);
    const stmts = ast.root.data.block.statements;
    try testing.expectEqual(@as(usize, 2), stmts.len);
    try testing.expect(stmts[0].data == .function_def);
    try testing.expect(stmts[1].data == .function_call);
    try testing.expectEqualStrings("add", stmts[0].data.function_def.name);
    try testing.expectEqual(@as(usize, 2), stmts[0].data.function_def.params.len);
    try testing.expectEqual(DataType.int, stmts[0].data.function_def.return_type);
}

test "supports forward calls and mutual recursion" {
    const testing = std.testing;
    const source =
        \\is_even(4)
        \\fn is_even(n: int) -> boolean {
        \\    if (n == 0) { true } else { is_odd(n - 1) }
        \\}
        \\fn is_odd(n: int) -> boolean {
        \\    if (n == 0) { false } else { is_even(n - 1) }
        \\}
    ;

    var ast = try programParse(source, testing.allocator);
    defer ast.deinit();

    try testing.expect(ast.root.data == .block);
    try testing.expectEqual(@as(usize, 3), ast.root.data.block.statements.len);
}

test "rejects access to top-level variables from functions" {
    const testing = std.testing;
    const source =
        \\x = 1
        \\fn get_x() -> int {
        \\    x
        \\}
        \\get_x()
    ;

    try testing.expectError(error.UndefinedVariable, programParse(source, testing.allocator));
}

test "rejects function calls with wrong argument type" {
    const testing = std.testing;
    const source =
        \\fn halve(x: float) -> float {
        \\    x / 2.0
        \\}
        \\halve(true)
    ;

    try testing.expectError(error.ArgumentTypeMismatch, programParse(source, testing.allocator));
}
