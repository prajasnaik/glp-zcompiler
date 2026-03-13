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

### Functions

Typed-return function:

```text
fn identifier(param_name: type, ...) -> return_type {
    statements
    return expression
}
```

Void function (no return type):

```text
fn identifier(param_name: type, ...) {
    statements
}
```

Rules in the current implementation:

- functions must be declared at top level
- parameter types are mandatory and static
- `return` is explicit only (`return expression`)
- no implicit return from final expressions
- if return type is declared via `->`, at least one explicit `return` is required
- if return type is omitted, function is `void` and any `return` statement is a compile error
- function calls use positional arguments only
- functions may call functions declared later in the file
- recursion and mutual recursion are supported
- function bodies may access only parameters and locals, not top-level variables

## Expressions and precedence

Binding strengths (low to high):

1. `or`
2. `and`
3. comparison operators
4. `+`, `-`
5. `*`, `/`
6. `^` (right-associative)

Unary `!` is parsed at atom level.

Function calls bind at atom level, so they behave like primary expressions inside larger arithmetic or logical expressions.

## Types and runtime value behavior

- Numeric literals are parsed as `int` or `float`.
- Mixed arithmetic promotes to `float` in backend expression generation.
- Comparisons/logical operations produce integer truth values (`0` or `1`) in codegen.
- Function parameter types are explicit and static.
- Function return types are static when declared.
- Omitting `-> type` creates a `void` function.
- Supported scalar types are `int`, `float`, and `boolean`.

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
- `FunctionMustBeTopLevel`
- `ArgumentCountMismatch`
- `ArgumentTypeMismatch`
- `ReturnTypeMismatch`
- `ExpectedExplicitReturn`
- `VoidFunctionCannotReturnValue`
- `VoidValueInExpression`

Errors are printed with line/column context through token spans.
