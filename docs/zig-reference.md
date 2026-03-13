# Zig 0.15.2 Reference Map for This Repository

This file maps implementation patterns in this codebase to the official Zig 0.15.2 documentation.

Primary source: <https://ziglang.org/documentation/0.15.2/>

## 1) Modules, imports, and entry point

- `@import` usage and root module behavior:
  - <https://ziglang.org/documentation/0.15.2/#import>
  - <https://ziglang.org/documentation/0.15.2/#Compilation-Model>
  - <https://ziglang.org/documentation/0.15.2/#Entry-Point>

Project mapping:

- `src/main.zig` is executable root.
- `build.zig` wires module imports.

## 2) Error handling model (`!`, `try`, `catch`, `errdefer`)

- Errors overview: <https://ziglang.org/documentation/0.15.2/#Errors>
- Error union: <https://ziglang.org/documentation/0.15.2/#Error-Union-Type>
- `try`: <https://ziglang.org/documentation/0.15.2/#try>
- `catch`: <https://ziglang.org/documentation/0.15.2/#catch>
- `errdefer`: <https://ziglang.org/documentation/0.15.2/#errdefer>

Project mapping:

- `main`, parser API, and backend all return error unions.
- Parser uses `errdefer` for arena cleanup safety.

## 3) Optionals and unwrapping

- Optionals: <https://ziglang.org/documentation/0.15.2/#Optionals>
- Optional pointers: <https://ziglang.org/documentation/0.15.2/#Optional-Pointers>

Project mapping:

- CLI args and parse flow use `?T` values and explicit unwraps.

## 4) Memory and allocators

- Memory overview: <https://ziglang.org/documentation/0.15.2/#Memory>
- Choosing an allocator: <https://ziglang.org/documentation/0.15.2/#Choosing-an-Allocator>
- Lifetime/ownership: <https://ziglang.org/documentation/0.15.2/#Lifetime-and-Ownership>

Project mapping:

- `GeneralPurposeAllocator` in executable path.
- `ArenaAllocator` for AST lifetime.
- Explicit deinit patterns with `defer`.

## 5) Data modeling with enums/unions/structs

- Structs: <https://ziglang.org/documentation/0.15.2/#struct>
- Enums: <https://ziglang.org/documentation/0.15.2/#enum>
- Tagged unions: <https://ziglang.org/documentation/0.15.2/#Tagged-union>
- `switch` over enums/unions: <https://ziglang.org/documentation/0.15.2/#switch>

Project mapping:

- Token kinds: `enum`.
- AST nodes and literal values: `union(enum)`.
- Parser and backend rely on exhaustive `switch` control flow.

## 6) Slices, pointers, and UTF-8 strings

- Slices: <https://ziglang.org/documentation/0.15.2/#Slices>
- Pointers: <https://ziglang.org/documentation/0.15.2/#Pointers>
- String/slice coercions: <https://ziglang.org/documentation/0.15.2/#Type-Coercion-Slices-Arrays-and-Pointers>

Project mapping:

- Source text, token lexemes, and identifiers are `[]const u8` slices.
- Token span offsets track positions in byte slices.

## 7) Loops and flow constructs

- `while`: <https://ziglang.org/documentation/0.15.2/#while>
- `for`: <https://ziglang.org/documentation/0.15.2/#for>
- `if`: <https://ziglang.org/documentation/0.15.2/#if>
- blocks and labels: <https://ziglang.org/documentation/0.15.2/#Blocks>

Project mapping:

- Parser and backend traversal use `while`/`for` loops and labeled logic.

## 8) Build modes and safety checks

- Build modes: <https://ziglang.org/documentation/0.15.2/#Build-Mode>
- Illegal behavior and safety semantics: <https://ziglang.org/documentation/0.15.2/#Illegal-Behavior>
- `@setRuntimeSafety`: <https://ziglang.org/documentation/0.15.2/#setRuntimeSafety>

Project implication:

- Debug mode gives stronger runtime checks during compiler development.

## 9) Build script API

- Language reference section: <https://ziglang.org/documentation/0.15.2/#Zig-Build-System>
- Build-system guide: <https://ziglang.org/learn/build-system/>

Project mapping:

- `build.zig` uses standard target/optimize options, run step, test step, and artifact installation.

## 10) C ABI / external toolchain integration

- C interop: <https://ziglang.org/documentation/0.15.2/#C>
- Export/link ABI concepts: <https://ziglang.org/documentation/0.15.2/#Functions>

Project mapping:

- Backend emits assembly targeting SysV ABI and links with system GCC/libm (`pow`).

## Doc-comment conventions for future inline docs

- Doc comments: <https://ziglang.org/documentation/0.15.2/#Doc-Comments>
- Top-level doc comments: <https://ziglang.org/documentation/0.15.2/#Top-Level-Doc-Comments>
- Style guide doc-comment guidance: <https://ziglang.org/documentation/0.15.2/#Doc-Comment-Guidance>

Recommended usage:

- `//!` at file top for module purpose.
- `///` above public declarations and invariants.