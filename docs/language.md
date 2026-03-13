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

```text
fn identifier(param_name: type, ...) -> return_type {
	statements
	final_expression_or_value_statement
}
```

Rules in the current implementation:

- functions must be declared at top level
- parameter types are mandatory
- return types are mandatory
- the last value-producing statement/expression is the return value
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

- Numeric literals are parsed as int or float.
- Mixed arithmetic promotes to float in backend expression generation.
- Comparisons/logical operations produce integer truth values (`0` or `1`) in codegen.
- Function parameter and return types are explicit and currently support the scalar runtime types already handled by the backend (`int`, `float`, `boolean`).

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
- `FunctionMustEndWithValue`

Errors are printed with line/column context through token spans.