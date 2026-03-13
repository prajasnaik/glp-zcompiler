# Development Workflow

## Prerequisites

- Zig 0.15.2-compatible toolchain.
- GCC toolchain for assembling/linking generated `.s` outputs.
- Linux x86_64 environment (current backend expectation).

## Build the compiler

- Build via `zig build`.
- Binary appears in `zig-out/bin/glp_zcompiler`.

## Compile a DPL source to assembly

Use the compiler as:

- `glp_zcompiler <input.dpl> -o <output.s>`

The output directory must already exist.

## Assemble and run generated output

- Use GCC and link libm:
  - `gcc output.s -o output -lm`
- Run executable directly.

## Running tests

Current repository testing is mainly sample-driven and manual runtime validation.

- `zig build test` executes Zig test blocks defined in module/executable roots.
- Sample regression is done by compiling and running selected `samples/*.dpl`.

## Suggested validation checklist

1. `zig build`
2. Compile sample integer arithmetic (`samples/01_int_arithmetic.dpl`)
3. Compile sample float arithmetic (`samples/02_float_arithmetic.dpl`)
4. Compile conditional sample (`samples/06_if_else.dpl`)
5. Compile loop/fibonacci (`samples/09_fibonacci.dpl`)

## Build system notes

`build.zig` currently demonstrates common Zig build-graph patterns:

- `standardTargetOptions`
- `standardOptimizeOption`
- install artifact
- convenience `run` step
- test step for both module and executable roots

References:

- <https://ziglang.org/documentation/0.15.2/#Zig-Build-System>
- <https://ziglang.org/learn/build-system/>

## Contributor guidance

- Keep parser and backend changes in lockstep when introducing syntax.
- Add/extend sample files with each language feature.
- Prefer explicit allocator ownership and cleanup discipline.
- Keep diagnostics line/column aware via token spans.