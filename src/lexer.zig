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
};

pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Lexer {
        return .{
            .input = input,
            .pos = 0,
        };
    }

    pub fn next(self: *Lexer) Token {
        // Skip horizontal whitespace (spaces and tabs)
        while (self.pos < self.input.len and (self.input[self.pos] == ' ' or self.input[self.pos] == '\t')) {
            self.pos += 1;
        }

        if (self.pos >= self.input.len) {
            return .{ .token_type = .eof, .lexeme = "" };
        }

        const start = self.pos;
        const ch = self.input[self.pos];

        // Single-character tokens and newlines
        switch (ch) {
            '\n' => {
                self.pos += 1;
                return .{ .token_type = .newline, .lexeme = self.input[start..self.pos] };
            },
            '\r' => {
                self.pos += 1;
                if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                return .{ .token_type = .newline, .lexeme = self.input[start..self.pos] };
            },
            '+' => {
                self.pos += 1;
                return .{ .token_type = .plus, .lexeme = self.input[start..self.pos] };
            },
            '-' => {
                self.pos += 1;
                return .{ .token_type = .minus, .lexeme = self.input[start..self.pos] };
            },
            '*' => {
                self.pos += 1;
                return .{ .token_type = .star, .lexeme = self.input[start..self.pos] };
            },
            '/' => {
                self.pos += 1;
                return .{ .token_type = .slash, .lexeme = self.input[start..self.pos] };
            },
            '^' => {
                self.pos += 1;
                return .{ .token_type = .caret, .lexeme = self.input[start..self.pos] };
            },
            '=' => {
                self.pos += 1;
                return .{ .token_type = .equal, .lexeme = self.input[start..self.pos] };
            },
            '(' => {
                self.pos += 1;
                return .{ .token_type = .l_paren, .lexeme = self.input[start..self.pos] };
            },
            ')' => {
                self.pos += 1;
                return .{ .token_type = .r_paren, .lexeme = self.input[start..self.pos] };
            },
            '{' => {
                self.pos += 1;
                return .{ .token_type = .l_brace, .lexeme = self.input[start..self.pos] };
            },
            '}' => {
                self.pos += 1;
                return .{ .token_type = .r_brace, .lexeme = self.input[start..self.pos] };
            },
            else => {},
        }

        // Identifiers
        if (isAlpha(ch)) {
            while (self.pos < self.input.len and isAlnum(self.input[self.pos])) {
                self.pos += 1;
            }
            return .{ .token_type = .identifier, .lexeme = self.input[start..self.pos] };
        }

        // Numbers
        if (isDigit(ch) or ch == '.') {
            while (self.pos < self.input.len and (isDigit(self.input[self.pos]) or self.input[self.pos] == '.')) {
                self.pos += 1;
            }
            return .{ .token_type = .number, .lexeme = self.input[start..self.pos] };
        }

        self.pos += 1;
        return .{ .token_type = .invalid, .lexeme = self.input[start..self.pos] };
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
