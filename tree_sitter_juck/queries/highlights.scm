; juck highlighting. In juck, strings are symbols (names) and literal text
; is written {"str": "..."}, so most strings are highlighted as names.

(comment) @comment
(number) @number
[(true) (false)] @boolean
(null) @constant.builtin
(escape_sequence) @string.escape
["[" "]" "{" "}"] @punctuation.bracket
["," ":"] @punctuation.delimiter

; Any symbol: a variable or parameter name.
(array (string) @variable)

; The head of a form: a function call...
(array . (string) @function.call)

; ...a built-in...
(#any-of? @_head "+" "-" "*" "/" "%" "<" "<=" ">" ">=" "=" "!=" "not" "print"
    "to-data" "symbol" "gensym" "eval"))
((array . (string (string_content) @_head) @function.builtin)
  (#match? @_head "^data-"))

; ...or a special form.
((array . (string (string_content) @_head) @keyword)
  (#any-of? @_head "def" "fn" "lambda" "macro" "type" "if" "let" "do" "data" "template" "insert" "splice"))

; Keys of objects (definition objects, type objects).
(pair key: (string) @property)

; {"str": "..."}: literal text.
(object
  (pair
    key: (string (string_content) @_key)
    value: (string) @string)
  (#eq? @_key "str"))

; Type positions: {"type": T}, {"returns": T}, and [name, T] pairs in params.
(pair
  key: (string (string_content) @_key)
  value: (string) @type
  (#any-of? @_key "type" "returns"))
(pair
  key: (string (string_content) @_key)
  value: (array (array . (string) (string) @type))
  (#eq? @_key "params"))
