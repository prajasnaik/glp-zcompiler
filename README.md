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
- [x] Functions (`fn name(args) -> type { ... }`)

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

Compile a function sample:

```sh
./zig-out/bin/glp_zcompiler samples/15_function_add.dpl -o outputs/function_add.s
gcc outputs/function_add.s -o outputs/function_add -lm
./outputs/function_add
```

## Function syntax

Functions are top-level declarations using explicit parameter types, with optional return type:

```text
fn add(a: int, b: int) -> int {
	return a + b
}
```

Current function rules:

- functions are declared with `fn`
- parameters require explicit types
- `return` statements are explicit; implicit return is not supported
- `-> type` is optional:
	- if present, function returns that type and must use explicit `return <expr>`
	- if omitted, the function is `void` and any `return` is a compile error
- functions may call functions defined later in the file
- recursion and mutual recursion are supported
- functions can access only their parameters and locals in this first version
- top-level statements still form the executable `main` program

## Sample regression runner

The repository includes `test.py`, a Python-based end-to-end regression runner for all `.dpl` files in `samples/`.

### Setup

You need these tools available on your `PATH`:

- `python3`
- `zig`
- `gcc`

`test.py` builds the compiler, compiles each sample to assembly, links it, runs it, and checks the printed result against the expected output table embedded in the script.

### Run it

```sh
python3 test.py
```

On success, it prints one `PASS` line per sample followed by a summary.

If you add a new file under `samples/`, also add its expected printed output to the `EXPECTED_OUTPUTS` map in `test.py`.

## Zig references used for this repository

- Zig Language Reference 0.15.2: <https://ziglang.org/documentation/0.15.2/>
- Zig Build System Guide: <https://ziglang.org/learn/build-system/>
