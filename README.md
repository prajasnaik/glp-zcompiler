# DPL-Compiler

This is a repo for a new programming language with difference equations as the thinking paradigm. All variable assignments, loops, etc. need to be with this in mind. The current progress is that we have a valid compiler for arithmetic.

## Next Steps (TODOs)

- [x] float-native operation support. So the output is not converted to int before printing.
- [x] support for file paths rather than just file names
- [x] handling assignments using symbol table
- [x] building conditionals
- [x] building while loop
- [x] adding ' operator for difference equation logic
- [ ] function support

## Prerequisites


**Supported Platform:**

- x86 Linux systems only

**Required Software:**

- Zig (version 15.2 or below)
- GNU GCC (for linking and executable generation)

## Usage

Clone the repository:

```sh
git clone https://github.com/prajasnaik/dpl-compiler.git
cd dpl-compiler
```

Build the compiler:

```sh
zig build
```

Run the compiler with an input source file and an output path:

```sh
./zig-out/bin/dpl-compiler <input.dpl> -o <path/to/output.s>
```

The output directory must already exist. For example, using the provided samples:

```sh
./zig-out/bin/dpl-compiler samples/09_fibonacci.dpl -o outputs/fibonacci.s
```

Compile the generated assembly into an executable:

```sh
gcc outputs/fibonacci.s -o outputs/fibonacci -lm
```

Run the executable:

```sh
./outputs/fibonacci
```
