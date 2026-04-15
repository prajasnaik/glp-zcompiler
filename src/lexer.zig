const std = @import("std");

pub const TokenType = enum {
    // Literals & Identifiers
    number,
    string,
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
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    comma,
    colon,

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

pub const Token = struct {
    token_type: TokenType,
    lexeme: []const u8,
    start: usize, // <-- Added for Span
    end: usize, // <-- Added for Span
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Lexer {
        return .{ .input = input, .pos = 0 };
    }

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
            '[' => {
                self.pos += 1;
                return self.makeToken(.l_bracket, start);
            },
            ']' => {
                self.pos += 1;
                return self.makeToken(.r_bracket, start);
            },
            '{' => {
                self.pos += 1;
                return self.makeToken(.l_brace, start);
            },
            '}' => {
                self.pos += 1;
                return self.makeToken(.r_brace, start);
            },
            ',' => {
                self.pos += 1;
                return self.makeToken(.comma, start);
            },
            ':' => {
                self.pos += 1;
                return self.makeToken(.colon, start);
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
            '"' => {
                const contents_start = self.pos + 1;
                var i = contents_start;
                var escaped = false;
                while (i < self.input.len) : (i += 1) {
                    const c = self.input[i];
                    if (escaped) {
                        escaped = false;
                        continue;
                    }
                    if (c == '\\') {
                        escaped = true;
                        continue;
                    }
                    if (c == '"') {
                        self.pos = i + 1;
                        return .{
                            .token_type = .string,
                            .lexeme = self.input[contents_start..i],
                            .start = start,
                            .end = self.pos,
                        };
                    }
                    if (c == '\n' or c == '\r') break;
                }
                self.pos = i;
                return self.makeToken(.invalid, start);
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
