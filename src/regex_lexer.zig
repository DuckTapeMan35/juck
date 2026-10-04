const std = @import("std");
const gex = @import("ezi_gex");
const token = @import("token");
const Tag = token.Tag;
const Token = token.Token;

const LexError = error{
    NoClosingQuote,
    NewlineInString,
    EmptyNumber,
    LeadingDot,
    LeadingZero,
    MultipleDots,
    TrailingDot,
    MissingExponentDigits,
    UnexpectedChar,
    UnclosedComment,
};

const Lexeme = union(enum) {
    tag: Tag,
    skip,
};

/// An action gets the matched text and decides what it becomes.
const Action = *const fn (text: []const u8) LexError!Lexeme;

const Rule = struct {
    re: gex.Regex,
    action: Action,
};

/// Each pattern is compiled to a minimized DFA at comptime; a typo in a pattern is a compile error.
fn rule(comptime pattern: []const u8, comptime action: Action) Rule {
    return .{ .re = comptime gex.compileComptime(pattern, .{}), .action = action };
}

// actions
fn string(text: []const u8) LexError!Lexeme {
    return .{ .tag = .{ .string = text[1 .. text.len - 1] } };
}

fn int(text: []const u8) LexError!Lexeme {
    return .{ .tag = .{ .int = text } };
}

fn float(text: []const u8) LexError!Lexeme {
    return .{ .tag = .{ .float = text } };
}

fn skip(_: []const u8) LexError!Lexeme {
    return .skip;
}

/// An action that always produces the same tag.
fn emit(comptime tag: Tag) Action {
    return struct {
        fn f(_: []const u8) LexError!Lexeme {
            return .{ .tag = tag };
        }
    }.f;
}

/// An action that always reports the same error.
fn fail(comptime err: LexError) Action {
    return struct {
        fn f(_: []const u8) LexError!Lexeme {
            return err;
        }
    }.f;
}

// rules
const int_re = "-?(?:0|[1-9][0-9]*)";
const str_body = "\"(?:[^\"\\\\\\n]|\\\\[^\\n])*";

const rules = [_]Rule{
    rule("[ \\t\\r\\n]+", skip),
    rule("//[^\n]*", skip),
    rule("/\\*(?:[^*]|\\*+[^*/])*\\*+/", skip),

    rule(str_body ++ "\"", string),
    rule(int_re, int),
    rule(int_re ++ "(?:\\.[0-9]+(?:[eE][+-]?[0-9]+)?|[eE][+-]?[0-9]+)", float),

    rule("true", emit(.{ .bool = true })),
    rule("false", emit(.{ .bool = false })),
    rule("null", emit(.null)),

    rule("\\{", emit(.lbrace)),
    rule("\\}", emit(.rbrace)),
    rule("\\[", emit(.lbracket)),
    rule("\\]", emit(.rbracket)),
    rule(",", emit(.comma)),
    rule(":", emit(.colon)),

    // Error rules: they only win when no valid token matches a longer prefix.
    rule(str_body ++ "\\n", fail(error.NewlineInString)),
    rule(str_body ++ "\\\\?\\z", fail(error.NoClosingQuote)),
    rule("-?0[0-9]+", fail(error.LeadingZero)),
    rule("-?\\.", fail(error.LeadingDot)),
    rule(int_re ++ "\\.", fail(error.TrailingDot)),
    rule(int_re ++ "\\.[0-9]+\\.", fail(error.MultipleDots)),
    rule(int_re ++ "(?:\\.[0-9]+)?[eE][+-]?", fail(error.MissingExponentDigits)),
    rule("-", fail(error.EmptyNumber)),
    rule("/\\*(?:[^*]|\\*+[^*/])*\\**\\z", fail(error.UnclosedComment)),
};

// driver
pub fn lex(str: *[]u8, alloc: std.mem.Allocator) ![]Token {
    const input: []const u8 = str.*;

    // Per-search working memory, one per rule, reused for the whole input.
    var scratches: [rules.len]gex.Scratch = undefined;
    var initialized: usize = 0;
    defer for (scratches[0..initialized]) |*sc| sc.deinit(alloc);
    for (&rules, &scratches) |*r, *sc| {
        sc.* = try r.re.initScratch(alloc);
        initialized += 1;
    }

    var tokens: std.ArrayListUnmanaged(Token) = .empty;
    errdefer tokens.deinit(alloc);

    var pos: usize = 0;
    while (pos < input.len) {
        // Try every rule anchored at pos; keep the longest match.
        var best: ?usize = null;
        var best_len: usize = 0;
        for (&rules, &scratches, 0..) |*r, *sc, i| {
            const m = r.re.findAt(sc, input, .{ .start = pos, .anchored = true }) orelse continue;
            if (m.end - m.start > best_len) {
                best = i;
                best_len = m.end - m.start;
            }
        }

        const lexeme = if (best) |i|
            rules[i].action(input[pos .. pos + best_len])
        else
            error.UnexpectedChar;

        switch (lexeme catch |err| {
            report(err, input, pos);
            return error.InvalidInput;
        }) {
            .skip => {},
            .tag => |tag| try tokens.append(alloc, Token.new(tag, pos)),
        }
        pos += best_len;
    }

    str.* = str.*[str.*.len..];
    return tokens.toOwnedSlice(alloc);
}

fn report(err: LexError, input: []const u8, pos: usize) void {
    switch (err) {
        error.NoClosingQuote => std.debug.print("error at position {d}: string is never closed, missing '\"'\n", .{pos}),
        error.NewlineInString => std.debug.print("error at position {d}: string contains a line break, use \\n instead\n", .{pos}),
        error.EmptyNumber => std.debug.print("error at position {d}: '-' must be followed by a digit\n", .{pos}),
        error.LeadingDot => std.debug.print("error at position {d}: number cannot start with '.', write 0.5 instead of .5\n", .{pos}),
        error.LeadingZero => std.debug.print("error at position {d}: number cannot have leading zeros\n", .{pos}),
        error.MultipleDots => std.debug.print("error at position {d}: number has more than one '.'\n", .{pos}),
        error.TrailingDot => std.debug.print("error at position {d}: number cannot end with '.', write 1.0 instead of 1.\n", .{pos}),
        error.MissingExponentDigits => std.debug.print("error at position {d}: exponent needs at least one digit after 'e'\n", .{pos}),
        error.UnexpectedChar => std.debug.print("error at position {d}: unexpected character '{c}'\n", .{ pos, input[pos] }),
        error.UnclosedComment => std.debug.print("error at position {d}: comment is never closed, missing '*/'\n", .{pos}),
    }
}
