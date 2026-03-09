const std = @import("std");

pub const TokenType = enum {
    // Literals & Identifiers
    number,
    identifier,

    // Operators
    plus,
    minus,
    star,
    slash,
    caret,
    equal,

    // Grouping
    l_paren,
    r_paren,
    l_brace,
    r_brace,

    // Control
    newline,
    eof,
    invalid,
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
            else => {},
        }

        if (isAlpha(ch)) {
            while (self.pos < self.input.len and isAlnum(self.input[self.pos])) self.pos += 1;
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
