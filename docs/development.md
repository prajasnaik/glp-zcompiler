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
- `python3 test.py` runs the sample regression suite across every file in `samples/`.

### `test.py` setup

Before running `test.py`, make sure these tools are installed and available on `PATH`:

- `python3`
- `zig`
- `gcc`

The script will:

1. build the compiler with `zig build`
2. compile each `samples/*.dpl` file to assembly
3. link the generated assembly with `gcc -lm`
4. run the resulting executable
5. assert the printed output matches the expected result for that sample

Run it with:

- `python3 test.py`

If you add or rename a sample, update the `EXPECTED_OUTPUTS` map in `test.py` so the regression suite stays authoritative.

## Suggested validation checklist

1. `zig build`
2. `zig build test`
3. `python3 test.py`
4. If working on a specific feature, run its representative sample directly for faster iteration

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