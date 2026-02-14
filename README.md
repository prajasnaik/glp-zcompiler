# GLP-ZCompiler

This is a repo for a new programming language with difference equations as the thinking paradigm. All variable assignments, loops, etc. need to be with this in mind. The current progress is that we have a valid compiler for arithmetic.

## Next Steps (TODOs)

- [ ] float-native operation support. So the output is not converted to int before printing.
- [ ] support for file paths rather than just file names
- [ ] handling assignments using symbol table
- [ ] building conditionals
- [ ] building while loop
- [ ] adding ' operator for difference equation logic
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
git clone https://github.com/<your-org>/glp-zcompiler.git
cd glp-zcompiler
```

Build the assembly file:

```sh
zig build
```

Run the compiler (only file name can be specified right now; support for paths will be added):

```sh
./zig-out/bin/glp_zcompiler <filename.s>
```

Compile the generated assembly file:

```sh
gcc <filename.s> -o <filename> -lm
```

Run the executable:

```sh
./<filename>
```
