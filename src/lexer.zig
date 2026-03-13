//! Lexer for the `.dpl` language.
//! Produces tokens with source spans used by the parser and diagnostics.
const std = @import("std");

/// Token categories recognized by the `.dpl` lexer.
pub const TokenType = enum {
    // Literals & Identifiers
    number,
    identifier,

    // Binary Operators
    plus,
    minus,
    star,
    slash,
    caret,
    equal,
    equal_equal,
    not_equal,
    lt,
    gt,
    lt_equal,
    gt_equal,

    // Unary Operators
    bang,
    prime,

    // Grouping
    l_paren,
    r_paren,
    l_brace,
    r_brace,

    // Control
    newline,
    eof,
    invalid,

    // Keywords
    kw_true,
    kw_false,
    kw_if,
    kw_else,
    kw_and,
    kw_or,
    kw_while,
};

/// A lexical token with byte-range span into the original source.
pub const Token = struct {
    token_type: TokenType,
    lexeme: []const u8,
    start: usize,
    end: usize,
};

/// Stateful scanner over a source buffer.
pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    /// Create a lexer for an input source buffer.
    pub fn init(input: []const u8) Lexer {
        return .{ .input = input, .pos = 0 };
    }

    /// Return the next token and advance lexer state.
    pub fn next(self: *Lexer) Token {
        while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) {
            self.pos += 1;
        }

        if (self.pos >= self.input.len) {
            return .{ .token_type = .eof, .lexeme = "", .start = self.pos, .end = self.pos };
        }

        const start = self.pos;
        const ch = self.input[self.pos];

        switch (ch) {
            '\n' => {
                self.pos += 1;
                return self.makeToken(.newline, start);
            },
            '\r' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                return self.makeToken(.newline, start);
            },
            '+' => {
                self.pos += 1;
                return self.makeToken(.plus, start);
            },
            '-' => {
                self.pos += 1;
                return self.makeToken(.minus, start);
            },
            '*' => {
                self.pos += 1;
                return self.makeToken(.star, start);
            },
            '/' => {
                self.pos += 1;
                return self.makeToken(.slash, start);
            },
            '^' => {
                self.pos += 1;
                return self.makeToken(.caret, start);
            },
            '=' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '=') {
                    self.pos += 1;
                    return self.makeToken(.equal_equal, start);
                }
                return self.makeToken(.equal, start);
            },
            '(' => {
                self.pos += 1;
                return self.makeToken(.l_paren, start);
            },
            ')' => {
                self.pos += 1;
                return self.makeToken(.r_paren, start);
            },
            '{' => {
                self.pos += 1;
                return self.makeToken(.l_brace, start);
            },
            '}' => {
                self.pos += 1;
                return self.makeToken(.r_brace, start);
            },
            '<' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '=') {
                    self.pos += 1;
                    return self.makeToken(.lt_equal, start);
                }
                return self.makeToken(.lt, start);
            },
            '>' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '=') {
                    self.pos += 1;
                    return self.makeToken(.gt_equal, start);
                }
                return self.makeToken(.gt, start);
            },
            '!' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '=') {
                    self.pos += 1;
                    return self.makeToken(.not_equal, start);
                }
                return self.makeToken(.bang, start);
            },
            '`' => {
                self.pos += 1;
                return self.makeToken(.prime, start);
            },
            else => {},
        }

        if (isAlpha(ch)) {
            while (self.pos < self.input.len and isAlnum(self.input[self.pos])) self.pos += 1;
            const lexeme = self.input[start..self.pos];
            if (std.mem.eql(u8, lexeme, "true")) return self.makeToken(.kw_true, start);
            if (std.mem.eql(u8, lexeme, "false")) return self.makeToken(.kw_false, start);
            if (std.mem.eql(u8, lexeme, "if")) return self.makeToken(.kw_if, start);
            if (std.mem.eql(u8, lexeme, "else")) return self.makeToken(.kw_else, start);
            if (std.mem.eql(u8, lexeme, "and")) return self.makeToken(.kw_and, start);
            if (std.mem.eql(u8, lexeme, "or")) return self.makeToken(.kw_or, start);
            if (std.mem.eql(u8, lexeme, "while")) return self.makeToken(.kw_while, start);
            return self.makeToken(.identifier, start);
        }

        if (isDigit(ch) or ch == '.') {
            while (self.pos < self.input.len and (isDigit(self.input[self.pos]) or self.input[self.pos] == '.')) self.pos += 1;
            return self.makeToken(.number, start);
        }

        self.pos += 1;
        return self.makeToken(.invalid, start);
    }

    fn makeToken(self: *Lexer, token_type: TokenType, start: usize) Token {
        return .{
            .token_type = token_type,
            .lexeme = self.input[start..self.pos],
            .start = start,
            .end = self.pos,
        };
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn isAlnum(c: u8) bool {
        return isAlpha(c) or isDigit(c);
    }
};
