const options = @import("build_options");

const impl = switch (options.lexer) {
    .manual => @import("manual_lexer.zig"),
    .re2c => @import("re2c_lexer"),
};

pub const lex = impl.lex;
