/**
 * @file juck grammar for tree-sitter
 * @author duck <luis.tomas.nogueira@gmail.com>
 * @license GPL-3.0-or-later
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

export default grammar({
  name: "juck",

  // skipped between any 2 tokens
  extras: $ => [/\s/, $.comment],

  supertypes: $ => [$._value],

  rules: {
    // A file is a sequence of top-level forms.
    document: $ => repeat($._value),

    _value: $ => choice(
      $.object,
      $.array,
      $.string,
      $.number,
      $.true,
      $.false,
      $.null,
    ),

    object: $ => seq('{', commaSep($.pair), '}'),

    pair: $ => seq(
      field('key', $.string),
      ':',
      field('value', $._value),
    ),

    array: $ => seq('[', commaSep($._value), ']'),

    string: $ => seq(
      '"',
      repeat(choice($.string_content, $.escape_sequence)),
      '"',
    ),

    // token.immediate: no whitespace or comments may be skipped inside a string.
    string_content: _ => token.immediate(prec(1, /[^\\"\n]+/)),

    escape_sequence: _ => token.immediate(seq(
      '\\',
      choice(/["\\/bfnrt]/, /u[0-9a-fA-F]{4}/),
    )),

    number: _ => token(seq(
      optional('-'),
      choice('0', /[1-9][0-9]*/),
      optional(seq('.', /[0-9]+/)),
      optional(seq(/[eE]/, optional(/[+-]/), /[0-9]+/)),
    )),

    true: _ => 'true',
    false: _ => 'false',
    null: _ => 'null',

    // Not JSON: remove this rule (and it from `extras`) for strict JSON.
    comment: _ => token(choice(
      seq('//', /[^\n]*/),
      seq('/*', /[^*]*\*+([^/*][^*]*\*+)*/, '/'),
    )),
  }
});

/**
 * Zero or more rules separated by commas, no trailing comma.
 * @param {RuleOrLiteral} rule
 */
function commaSep(rule) {
  return optional(seq(rule, repeat(seq(',', rule)), optional(',')));
}
