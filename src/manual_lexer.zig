const std = @import("std");
const token = @import("token");
const Token = token.Token;
const Tag = token.Tag;

pub fn lex(str: *[]u8, alloc: std.mem.Allocator) ![]Token {
    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    errdefer tokens.deinit(alloc);
    const og_len = str.*.len;
    while (str.*.len > 0) {
        const pos = og_len - str.*.len;
        const is_comment = skip_comment(str) catch {
            std.debug.print("error at position {d}: comment is never closed, missing '*/'\n", .{pos});
            return error.InvalidInput;
        };
        if (is_comment) continue;
        const string = lex_str(str) catch |err| {
            switch (err) {
                error.NoClosingQuote => std.debug.print("error at position {d}: string is never closed, missing '\"'\n", .{pos}),
                error.NewlineInString => std.debug.print("error at position {d}: string contains a line break, use \\n instead\n", .{pos}),
            }
            return error.InvalidInput;
        };
        if (string) |tag| {
            const t = Token.new(tag, pos);
            try tokens.append(alloc, t);
            continue;
        }
        const number = lex_number(str) catch |err| {
            switch (err) {
                error.EmptyNumber => std.debug.print("error at position {d}: '-' must be followed by a digit\n", .{pos}),
                error.LeadingDot => std.debug.print("error at position {d}: number cannot start with '.', write 0.5 instead of .5\n", .{pos}),
                error.LeadingZero => std.debug.print("error at position {d}: number cannot have leading zeros\n", .{pos}),
                error.MultipleDots => std.debug.print("error at position {d}: number has more than one '.'\n", .{pos}),
                error.TrailingDot => std.debug.print("error at position {d}: number cannot end with '.', write 1.0 instead of 1.\n", .{pos}),
                error.MissingExponentDigits => std.debug.print("error at position {d}: exponent needs at least one digit after 'e'\n", .{pos}),
            }
            return error.InvalidInput;
        };
        if (number) |tag| {
            const t = Token.new(tag, pos);
            try tokens.append(alloc, t);
            continue;
        }
        const literal = lex_literal(str);
        if (literal) |tag| {
            const t = Token.new(tag, pos);
            try tokens.append(alloc, t);
            continue;
        }

        switch (str.*[0]) {
            ' ', '\n', '\t', '\r' => {
                str.* = str.*[1..];
            },
            '{', '}', '[', ']', ',', ':' => {
                switch (str.*[0]) {
                    '{' => try tokens.append(alloc, Token.new(.lbrace, pos)),
                    '}' => try tokens.append(alloc, Token.new(.rbrace, pos)),
                    '[' => try tokens.append(alloc, Token.new(.lbracket, pos)),
                    ']' => try tokens.append(alloc, Token.new(.rbracket, pos)),
                    ',' => try tokens.append(alloc, Token.new(.comma, pos)),
                    ':' => try tokens.append(alloc, Token.new(.colon, pos)),
                    else => unreachable,
                }
                str.* = str.*[1..];
            },
            else => |c| {
                std.debug.print("error at position {d}: unexpected character '{c}'\n", .{ pos, c });
                return error.InvalidInput;
            },
        }
    }
    return tokens.toOwnedSlice(alloc);
}

fn lex_str(str: *[]u8) !?Tag {
    if (str.*.len == 0 or str.*[0] != '"') return null;

    // skip opening quote
    var i: usize = 1;
    while (i < str.*.len) : (i += 1) {
        if (str.*[i] == '\\') {
            i += 1;
            continue;
        }
        if (str.*[i] == '\n') return error.NewlineInString;
        if (str.*[i] == '"') break;
    } else {
        return error.NoClosingQuote; // ran out of input, no closing quote
    }

    const tag = Tag{ .string = str.*[1..i] };
    str.* = str.*[i + 1 ..];
    return tag;
}

fn lex_number(str: *[]u8) !?Tag {
    if (str.*.len == 0) return null;
    const negative = str.*[0] == '-';
    if (negative and str.*.len == 1) return error.EmptyNumber;
    if (str.*[0] == '.' or (negative and str.*[1] == '.')) return error.LeadingDot;
    var dot_seen = false;
    var has_numbers = false;
    var leading_zero = false;
    var has_exp = false;
    var i: usize = if (negative) 1 else 0;
    while (i < str.*.len) : (i += 1) {
        const c = str.*[i];
        switch (c) {
            '0'...'9' => {
                if (leading_zero and !dot_seen) return error.LeadingZero;
                if (c == '0') {
                    if (i == 0 or (negative and i == 1)) {
                        leading_zero = true;
                    }
                }
                has_numbers = true;
            },
            '.' => {
                if (dot_seen) return error.MultipleDots;
                dot_seen = true;
            },
            else => break,
        }
    }
    if (!has_numbers) return null;
    if (str.*[i - 1] == '.') return error.TrailingDot;
    if (i < str.*.len and (str.*[i] == 'e' or str.*[i] == 'E')) {
        i += 1;
        if (i < str.*.len and (str.*[i] == '-' or str.*[i] == '+')) i += 1;
        while (i < str.*.len) : (i += 1) {
            const c = str.*[i];
            switch (c) {
                '0'...'9' => has_exp = true,
                else => break,
            }
        }
        if (!has_exp) return error.MissingExponentDigits;
    }
    const tag = if (dot_seen or has_exp) Tag{ .float = str.*[0..i] } else Tag{ .int = str.*[0..i] };
    str.* = str.*[i..];
    return tag;
}

fn lex_literal(str: *[]u8) ?Tag {
    if (std.mem.startsWith(u8, str.*, "true")) {
        str.* = str.*[4..];
        return Tag{ .bool = true };
    } else if (std.mem.startsWith(u8, str.*, "false")) {
        str.* = str.*[5..];
        return Tag{ .bool = false };
    } else if (std.mem.startsWith(u8, str.*, "null")) {
        str.* = str.*[4..];
        return Tag{ .null = {} };
    }
    return null;
}

fn skip_comment(str: *[]u8) !bool {
    if (str.*.len < 2 or str.*[0] != '/') return false;
    switch (str.*[1]) {
        '/' => {
            const end = std.mem.indexOfScalar(u8, str.*, '\n') orelse str.*.len;
            str.* = str.*[end..];
        },
        '*' => {
            const end = std.mem.indexOf(u8, str.*[2..], "*/") orelse return error.UnclosedComment;
            str.* = str.*[2 + end + 2 ..];
        },
        else => return false,
    }
    return true;
}
