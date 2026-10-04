const options = @import("build_options");

const impl = switch (options.lexer) {
    .manual => @import("manual_lexer"),
    .regex => @import("regex_lexer"),
};

pub const lex = impl.lex;
