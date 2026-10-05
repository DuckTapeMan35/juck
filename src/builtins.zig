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
            .@"to-data", .symbol, .eval => 1,
            .@"data-slice" => 3,
            else => 2,
        };
    }
};
