# GLP-ZCompiler

GLP-ZCompiler is a toy compiler for a recurrence-oriented language (`.dpl`) that emits x86-64 Linux assembly.

The pipeline is:

1. Lexing
2. Parsing to AST
3. Assembly generation
4. External assembly/link via GCC

## Documentation

Full documentation now lives in [`docs/`](./docs/README.md):

- Architecture: [`docs/architecture.md`](./docs/architecture.md)
- Current language behavior: [`docs/language.md`](./docs/language.md)
- Sample-by-sample guide: [`docs/samples.md`](./docs/samples.md)
- Zig 0.15.2 concept map used by this codebase: [`docs/zig-reference.md`](./docs/zig-reference.md)
- Build and contributor workflow: [`docs/development.md`](./docs/development.md)

## Current feature status

- [x] Integer and float arithmetic
- [x] Operator precedence (including right-associative power)
- [x] Symbol-table-backed assignments
- [x] Conditionals (`if` / `else`)
- [x] `while` loops
- [x] Prime assignment semantics inside loops (`` ` ``)
- [x] Input/output file-path CLI
- [ ] Functions

## Platform and toolchain

- Supported target: x86 Linux
- Zig: 0.15.2-compatible toolchain
- GNU GCC: required to assemble/link generated `.s`

## Quick start

Build compiler:

```sh
zig build
```

Compile a sample to assembly:

```sh
mkdir -p outputs
./zig-out/bin/glp_zcompiler samples/09_fibonacci.dpl -o outputs/fibonacci.s
```

Assemble and run:

```sh
gcc outputs/fibonacci.s -o outputs/fibonacci -lm
./outputs/fibonacci
```

## Zig references used for this repository

- Zig Language Reference 0.15.2: <https://ziglang.org/documentation/0.15.2/>
- Zig Build System Guide: <https://ziglang.org/learn/build-system/>
