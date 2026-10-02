const std = @import("std");

pub fn lex(str: *[]u8, alloc: std.mem.Allocator) ![][]const u8 {
    var tokens = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
    errdefer tokens.deinit(alloc);
    while (str.*.len > 0) {
        const json_str = lex_str(str, alloc) catch {
            std.debug.print("Expected end-of-string quote", .{});
            return error.InvalidInput;
        };
        if (json_str) |new_token| {
            errdefer alloc.free(new_token);
            try tokens.append(alloc, new_token);
            continue;
        }

        //TODO: lex bools, nulls and numbers

        switch (str.*[0]) {
            ' ', '\n' => {
                str.* = str.*[1..];
            },
            '{', '}', ',', ':' => {
                const tok: []const u8 = switch (str.*[0]) {
                    '{' => "{",
                    '}' => "}",
                    ',' => ",",
                    ':' => ":",
                    else => unreachable,
                };
                try tokens.append(alloc, tok);
                str.* = str.*[1..];
            },
            else => |c| {
                std.debug.print("Unexpected character: {}", .{c});
                return error.InvalidInput;
            },
        }
    }
    return tokens.toOwnedSlice(alloc);
}

fn lex_str(str: *[]u8, alloc: std.mem.Allocator) !?[]const u8 {
    var json_str = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer json_str.deinit(alloc);

    if (str.*.len == 0 or str.*[0] != '"') return null;

    // skip opening quote
    var i: usize = 1;
    while (i < str.*.len) : (i += 1) {
        const c = str.*[i];
        if (c == '"') {
            str.* = str.*[i + 1 ..];
            return try json_str.toOwnedSlice(alloc);
        }
        try json_str.append(alloc, c);
    }

    return error.InvalidInput;
}

fn lex_number(str: *[]u8, alloc: std.mem.Allocator) !?[]const u8 {
    var json_n = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer json_n.deinit(alloc);
    if (str.*.len == 0) return null;
}
fn lex_bool(str: *[]u8, alloc: std.mem.Allocator) !?[]const u8 {
    _ = str;
    _ = alloc;
}

fn lex_null(str: *[]u8, alloc: std.mem.Allocator) !?[]const u8 {
    _ = str;
    _ = alloc;
}
