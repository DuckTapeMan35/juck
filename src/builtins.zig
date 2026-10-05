const std = @import("std");

pub const Builtin = enum {
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

    pub fn lookup(text: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, text);
    }

    pub fn name(self: Builtin) []const u8 {
        return @tagName(self);
    }
};
