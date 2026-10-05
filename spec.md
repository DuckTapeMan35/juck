# juck

juck is a statically typed, Lisp-like language whose syntax is JSON.
Code is data: a program is a JSON value, so other languages can load,
modify and re-emit it with an ordinary JSON parser.

# Source syntax

Source files (`.juck`) are JSONC: JSON plus

- `//` line comments and `/* */` block comments
- trailing commas in arrays and objects (`[1, 2,]`, `{"a": 1,}`)

A file holds exactly one value, like a JSON document: an array whose
elements are the program's top-level forms.

```json
[
  ["def", { "name": "pi", "type": "f64" }, 3.14159],
  ["print", "pi"]
]
```

Comments are discarded by the reader. Anything that must survive a
round trip through other tools (like documentation) belongs in the
code as data, for example a `"doc"` key in a definition.

Objects must not contain duplicate keys; the reader rejects them.

# Interchange format

`juck <file> --json` emits strict JSON (no comments, no trailing
commas) that any JSON parser accepts:

```json
{"juck": "0.1", "program": [ ... ]}

```

`"juck"` is the format version; it changes when the shape of code
changes. Compiled programs embed the same JSON.

Anything whose order matters is written as an array, never as object
keys: JSON does not guarantee key order, and some languages' parsers
do not preserve it.

# Values in code

How each kind of JSON value is read as code:

- _number_: a numeric literal. Integers (no `.`, `e` or `E`) are `i64`,
  everything else is `f64`.
- `true`, `false`: boolean literals.
- `null`: the null value.
- _string_: a **symbol**, meaning a name: a variable, a function, a type
  or a special form. Strings are never literal text in code.
- _array_: a form. The first element is the head; see [Forms](#forms).
- _object_: a literal object; see [Literal objects](#literal-objects).

## Names

A symbol may not contain `.` (see [Constructing and accessing values](#constructing-and-accessing-values))
or start with `@` (see [Intrinsics](#intrinsics)).

# Literal objects

An object in expression position must have exactly one key, and the
key says what kind of literal it is.

- `{"str": "text"}`: a string literal.

Any other object in expression position is an error. Objects also
appear inside special forms (like the definition object of `fn`),
where the form defines what keys mean, and as type expressions; see
[Types](#types).

# Forms

A form is an array `[head, args...]`. What happens depends on the head:

- A _special form_ has its own evaluation rules; see [Special forms](#special-forms).
- An _intrinsic_ is called like a function, but the compiler handles
  it; see [Intrinsics](#intrinsics).
- Anything else is a _function call_: the head and the arguments are
  evaluated left to right, then the function is applied to the
  arguments. The head may be any expression, so
  `[["make-adder", 1], 5]` calls the function `make-adder` returns.

Everything that can be an ordinary function is one, and lives in the
standard library rather than in this spec.

## Special forms

Special forms are the forms that can't be functions: they bind names,
define types, or control whether and when their arguments are
evaluated. Their names are reserved and cannot be redefined:
`def`, `fn`, `lambda`, `type`, `if`, `let`, `do`, `data`.

### def

Defines a global name.

```json
["def", { "name": "pi", "type": "f64" }, 3.14159]
```

The definition object has a `"name"` and a `"type"`, both required.

### fn

Defines a named function.

```json
[
  "fn",
  {
    "name": "add",
    "params": [
      ["a", "i64"],
      ["b", "i64"]
    ],
    "returns": "i64"
  },
  ["+", "a", "b"]
]
```

Definition object keys:

- `"name"` (required): the function's name.
- `"params"` (required): an array of `[name, type]` pairs, in order.
- `"returns"` (required): the return type.
- `"doc"` (optional): a documentation string.

The body is one or more expressions; the value of the last one is
the function's result.

### lambda

An anonymous function. Same definition object as `fn`, without
`"name"`.

```json
["lambda", { "params": [["x", "i64"]], "returns": "i64" }, ["*", "x", "x"]]
```

A lambda can use names from the scope it is defined in; it keeps
them for as long as it exists (it is a closure).

### type

Names a type.

```json
[
  "type",
  "Shape",
  {
    "union": [
      ["circle", "f64"],
      [
        "rect",
        {
          "struct": [
            ["w", "f64"],
            ["h", "f64"]
          ]
        }
      ]
    ]
  }
]
```

### if

```json
["if", condition, then, else]

```

`condition` must be a `bool`. Both branches are required and must
have the same type. Only the chosen branch is evaluated.

### let

Local bindings, evaluated in order; each binding can see the ones
before it. Each binding is a `[name, type, value]` triple.

```json
[
  "let",
  [
    ["x", "i64", 1],
    ["y", "i64", ["+", "x", 1]]
  ],
  ["*", "x", "y"]
]
```

The body is one or more expressions, as in `fn`.

### do

Evaluates expressions in order and returns the value of the last.

```json
["do", ["print", "x"], ["+", "x", 1]]
```

### data

Returns its argument as data, unevaluated.

```json
["data", ["+", 1, 2]]
```

The result has type `data`. Symbols in the argument stay symbols,
distinct from strings: `["data", "a"]` holds the symbol `a`, while
`["data", {"str": "a"}]` holds the string "a".

## Intrinsics

Intrinsics are called exactly like functions, but the compiler
handles them, usually because they must run at compile time. Their
names start with `@`.

- `["@import", {"str": "path"}]`: loads another module; see
  [Open questions](#open-questions).

Constructors and field access (see [Constructing and accessing
values](#constructing-and-accessing-values)) are also handled by the compiler, but keep their natural
syntax.

# Execution

A program is evaluated like a Lisp: the top-level forms are evaluated
in order, from first to last.

A name defined with `def` or `type` is available to every form after
it. Functions defined with `fn` at the top level are known to the
whole program, so a function body may call functions defined later in
the file, including functions that call each other. Calling a
function at the top level before its `fn` form has been evaluated is
an error.

# Constructing and accessing values

A named type is called like a function to construct a value:

```json
[
  [
    "type",
    "Point",
    {
      "struct": [
        ["x", "f64"],
        ["y", "f64"]
      ]
    }
  ],
  ["Point", 1.0, 2.0]
]
```

Arguments are the fields, in declaration order. A union value is
constructed through its variant:

```json
["Shape.circle", 2.0]
```

Fields are read with a dot:

```json
["+", "point.x", "point.y"]
```

A dotted symbol is shorthand for a `.` form, which tools that
generate code can use directly:

- `"point.x"` is `[".", "point", "x"]`
- `["point.scale", 2.0]` is `[[".", "point", "scale"], 2.0]`

# Types

A type is either a symbol naming a type, or a single-key object
describing a compound type.

## Primitive types

- `i64`: 64-bit signed integer
- `f64`: 64-bit float
- `bool`
- `str`: string
- `data`: any juck code as a value, in other words, any json type
- `null`: the type of `null`

There are no implicit conversions: an operation mixing `i64` and
`f64` is a type error.

Integers wider than 64 bits are a standard library concern, not
part of the core language.

## Compound types

Fields and variants are arrays of `[name, type]` pairs, so their
order is preserved; it determines memory layout and tag values.

- `{"struct": [[name, type], ...]}`: a record of named fields.
- `{"union": [[name, type], ...]}`: a tagged union; a value holds
  exactly one variant, and knows which one.
- `{"fn": {"params": [type, ...], "returns": type}}`: a function.
  Two function types are equal if their parameter types and return
  types are equal; parameter names are not part of the type.

Types can be nested, and named with [type](#type):

```json
[
  ["type", "IntOp", { "fn": { "params": ["i64"], "returns": "i64" } }],

  [
    "fn",
    { "name": "make-adder", "params": [["n", "i64"]], "returns": "IntOp" },
    ["lambda", { "params": [["x", "i64"]], "returns": "i64" }, ["+", "x", "n"]]
  ]
]
```

## Annotations

For now, every binding is annotated: definitions, function
parameters and return types, and `let` bindings. Type inference
will make some of these optional later.

# Open questions

- Other compound types: lists, maps.
- Type inference, starting with `let` bindings.
- Macros: likely an intrinsic for defining them; when are they
  expanded?
- Modules: what `@import` returns, and how a module exposes
  names (probably as an object).
- Methods: does `["point.scale", 2.0]` look up a field, or call
  a function with `point` as its first argument (like Zig)?
- Matching on union variants: reading which variant a value holds.
- Duplicate keys are rejected for now; could they express
  overloading later?
- Plain function pointers without captures, for C interop and
  native code.
