const std = @import("std");

pub const Builtin = enum {
    // arithmetic and comparison
    @"+",
    @"-",
    @"*",
    @"/",
    @"%",
    @"<",
    @"<=",
    @">",
    @">=",
    @"=",
    @"!=",
    not,
    print,

    // numbers
    @"i64-to-f64",
    @"f64-to-i64",
    @"i64-to-str",
    @"f64-to-str",

    // strings (UTF-8; lengths and positions in bytes)
    @"str-len",
    @"str-concat",
    @"str-slice",
    @"str-byte",
    @"str-from-byte",

    // code as data: inspecting
    @"data-null?",
    @"data-bool?",
    @"data-int?",
    @"data-float?",
    @"data-symbol?",
    @"data-array?",
    @"data-object?",
    @"data-len",
    @"data-get",
    @"data-slice",
    @"data-field",
    @"data-has?",

    // code as data: converting
    @"data-to-i64",
    @"data-to-f64",
    @"data-to-bool",
    @"data-to-str",
    @"to-data",
    symbol,

    // code as data: building and running
    @"data-array",
    gensym,
    eval,

    pub fn lookup(text: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, text);
    }

    pub fn name(self: Builtin) []const u8 {
        return @tagName(self);
    }

    /// The number of arguments, or null if it takes any number.
    pub fn arity(self: Builtin) ?usize {
        return switch (self) {
            .@"data-array" => null,
            .not, .print => 1,
            .@"data-null?", .@"data-bool?", .@"data-int?", .@"data-float?" => 1,
            .@"data-symbol?", .@"data-array?", .@"data-object?", .@"data-len" => 1,
            .@"data-to-i64", .@"data-to-f64", .@"data-to-bool", .@"data-to-str" => 1,
            .@"to-data", .symbol, .gensym, .eval => 1,
            .@"i64-to-f64", .@"f64-to-i64", .@"i64-to-str", .@"f64-to-str" => 1,
            .@"str-len", .@"str-from-byte" => 1,
            .@"data-slice", .@"str-slice" => 3,
            else => 2,
        };
    }
};
