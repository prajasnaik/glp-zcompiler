# Architecture

## High-level pipeline

1. Read source file (`.dpl`) in `src/main.zig`.
2. Tokenize input using `src/lexer.zig`.
3. Parse tokens into AST using `src/parser.zig`.
4. Generate x86-64 assembly using `src/asm_generator.zig`.
5. Assemble and link externally via GCC.

## Module responsibilities

### `src/main.zig`

- CLI argument parsing (`<input.dpl> -o <output.s>`).
- File existence and output directory checks.
- Source read and output file creation.
- Invokes parser API (`programParse`).
- Invokes backend API (`AsmGenerator.generate`).
- Emits debug logs for pipeline visibility.

### `src/lexer.zig`

- Converts byte stream into `Token`s.
- Emits explicit token types for:
  - arithmetic/comparison operators,
  - logical ops (`and`, `or`, `!`),
  - control flow (`if`, `else`, `while`),
  - delimiters (`() {}`),
  - assignment/equality,
  - `newline`, `eof`, `invalid`,
  - prime token (backtick).
- Records token spans (`start`, `end`) for diagnostics.

### `src/parser.zig`

- Defines AST node union `NodeData` and span-aware `Node`.
- Implements:
  - literal parsing (`int`, `float`, `boolean`),
  - variable references,
  - typed top-level function declarations,
  - typed function calls,
  - unary `!`,
  - precedence-based binary expression parsing,
  - assignment and prime-assignment statements,
  - `if/else`, `while`, and block parsing,
  - top-level program parse into root block.
- Maintains scoped symbol table with `StringHashMap` for variable definitions.
- Performs a header-collection pass for function signatures so forward calls and recursion work.
- Infers value kinds (int/float/boolean-ish) to guide code generation.
- Collects `prime_vars` per while body to support simultaneous updates.
- Uses arena allocation for AST lifetime management (`ParsedAst`).

### `src/asm_generator.zig`

- Emits Intel-syntax x86-64 assembly for Linux SysV ABI.
- Maintains stack slots for variables (`VarInfo`).
- Tracks register kind (`rax` for ints, `xmm0` for floats).
- Emits separate labels for top-level `fn` declarations and the program `main` body.
- Lowers typed function calls using SysV integer and XMM argument registers.
- Handles mixed int/float arithmetic with conversion paths.
- Handles `if`/`else` and `while` label generation.
- Implements prime assignment behavior by staging values in separate loop slots.
- Chooses `%ld` or `%f` printf format for the final top-level result after codegen.
- Uses `pow@PLT` for exponentiation.

## Function compilation flow

Function support adds two important stages to the existing pipeline:

1. A pre-parse signature scan records every top-level function header.
2. The main parser validates bodies and calls against those recorded signatures.

This allows:

- calls before definitions,
- recursion,
- mutual recursion.

At codegen time:

- each `fn` becomes a standalone text label with its own stack frame,
- parameters are copied from ABI argument registers into local stack slots,
- the function body leaves its final value in `rax` or `xmm0`,
- top-level non-function statements remain the executable program body emitted as `main`.

## Runtime assumptions and ABI notes

- Current target is x86 Linux.
- Output assembly expects libc + libm linkage (e.g. `gcc output.s -lm`).
- Floating call/print paths follow SysV varargs rules (`eax` register setup for `%f`).

## Memory model choices in this project

- `main`: `std.heap.GeneralPurposeAllocator` for runtime allocations.
- parser: `std.heap.ArenaAllocator` for AST allocations, deallocated once per parse.
- backend: hash maps for variable metadata and temporary prime slots.

See also: [`zig-reference.md`](./zig-reference.md) for Zig rationale behind these choices.