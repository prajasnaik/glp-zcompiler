# DPL Language (Current State)

This is the language behavior implemented in the repository today (not a future roadmap spec).

## Lexical elements

### Literals

- Integer numbers: `10`
- Float numbers: `1.5`
- Booleans: `true`, `false`

### Identifiers

- Variable names use alphanumeric/underscore pattern, lexer-driven.

### Operators

- Arithmetic: `+`, `-`, `*`, `/`, `^`
- Comparison: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Logical: `and`, `or`, `!`
- Assignment: `=`
- Prime marker: backtick `` ` ``

### Grouping and blocks

- Parentheses: `(` `)`
- Braces: `{` `}`
- Newlines act as statement separators.

## Statements

### Standard assignment

```text
x = expression
```

Defines a variable in the current scope (error if redefined in same scope).

### Prime assignment (loop-only)

```text
x` = expression
```

Rules:

- Valid only inside `while` body.
- Variable must already exist.
- Represents the “next-state” value for a variable.

The backend stages these values in prime slots and commits them together at loop end.

### If / else

```text
if (condition) statement_or_block
if (condition) statement_or_block else statement_or_block
```

### While

```text
while (condition) statement_or_block
```

## Expressions and precedence

Binding strengths (low to high):

1. `or`
2. `and`
3. comparison operators
4. `+`, `-`
5. `*`, `/`
6. `^` (right-associative)

Unary `!` is parsed at atom level.

## Types and runtime value behavior

- Numeric literals are parsed as int or float.
- Mixed arithmetic promotes to float in backend expression generation.
- Comparisons/logical operations produce integer truth values (`0` or `1`) in codegen.

## Errors currently surfaced

Representative parser errors include:

- `UndefinedVariable`
- `VariableAlreadyDefined`
- `UnexpectedToken`
- `UnmatchedParenthesis`
- `ExpectedWhileCondition`, `ExpectedWhileBody`
- `ExpectedIfCondition`, `ExpectedThenStatement`, `ExpectedElseStatement`
- `PrimeOutsideLoop`
- `ExpectedEqualAfterPrime`
- `ExpectedClosingBrace`

Errors are printed with line/column context through token spans.