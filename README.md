![Enso Logo](https://cdn.vectorstock.com/i/thumbs/07/69/red-enso-zen-japanese-circle-brush-stroke-vector-44400769.jpg)

# Enso 🐍
*A Python compiler–interpreter written in Zig*

Enso is an implementation of **Python in Zig** that treats **compilation and interpretation as two backends of the same system**.

Instead of relying on a traditional JIT or a purely interpreted runtime, Enso uses a unified architecture where Python code can be **partially evaluated**, **compiled**, or **interpreted** depending on what is known at compile time.

At the core of this design is **MIR** (Medium Internal Representation), which enables:
- Ahead-of-time (AoT) compilation
- Just-in-time (JIT) compilation
- Embedded interpretation
- Execution without requiring an external toolchain (assembler/linker)

The result is a system where Python programs can be compiled into **small, self-contained binaries**, while still supporting dynamic features like `eval`, REPLs, and runtime code generation.

The name *Enso* comes from the Zen circle, often associated with infinity, recursion, and self-reference. Like the ouroboros, Enso consumes itself:

> **Python is implemented in Python, which is compiled by Enso.**

---

## Table of Contents

- [Why Enso?](#why-enso)
- [Core Ideas](#core-ideas)
- [Architecture Overview](#architecture-overview)
- [Why MIR?](#why-mir)
- [Goals](#goals)
- [Non-Goals (for now)](#non-goals-for-now)
- [Development Environment](#development-environment)
- [Testing](#testing)
- [Tour of the Source](#tour-of-the-source)
- [Roadmap](#roadmap)
- [Related Work & Inspiration](#related-work--inspiration)
- [License](#license)

---

## Why Enso?

Python today lives at two extremes:

- **CPython**: ubiquitous, stable, but constrained by its C API and interpreter-centric design
- **PyPy**: highly advanced, but limited adoption due in part to C-extension compatibility and ecosystem friction

Enso takes a different path:

- Python is treated as a **compilable language first**
- Interpretation exists as a **fallback mechanism**, not the core execution model
- The **entire stack**—language, standard library, and packages—can be optimized end-to-end

This enables optimizations similar to **whole-program compilation and LTO**, even for a dynamic language.

---

## Core Ideas

### 1. One IR, Multiple Execution Modes

Enso parses Python source into **bytecode-equivalent IR** that is *semantically identical* to CPython’s `dis` output:

    python -m dis source.py

Each instruction in this IR can be:
- **compiled ahead-of-time**
- **compiled just-in-time**
- **interpreted**

There is **no separate interpreter and compiler**—only different execution strategies over the same representation.

---

### 2. Partial Evaluation as the Primary Optimization

The first pass of a program is interpreted.

Values discovered at runtime are treated as **compile-time constants for subsequent passes**, enabling aggressive specialization.

This allows Enso to:
- eliminate dynamic overhead where possible
- specialize functions automatically
- avoid the complexity of traditional JIT pipelines

---

### 3. Python Implemented in Python

Inspired by systems like TruffleRuby, Enso aims to implement Python in itself:

- The standard library is written in Python
- Runtime behavior migrates out of Zig over time
- Zig becomes the execution substrate, not the language definition

---

## Architecture Overview

    Python Source
         │
         ▼
      Lexer / Parser
         │
         ▼
     CPython-equivalent IR
         │
         ├──► Interpreter (runtime-only paths)
         │
         └──► MIR Backend
                ├─ AoT compilation → native binary
                ├─ JIT compilation → runtime execution
                └─ C emission → portable builds

The interpreter, compiler, and runtime all coexist and can be **linked into a single binary**.

---

## Why MIR?

[MIR](https://github.com/vnmakarov/mir) is a compiler infrastructure designed for simplicity, embeddability, and flexibility.

It aligns with Enso’s goals in ways traditional compiler backends do not:

- **No external toolchain required**
  - No dependency on system linker/assembler
  - Ideal for shipping self-contained binaries

- **Built-in JIT support**
  - Enables REPLs, `eval`, and dynamic execution
  - No need for a separate JIT architecture

- **Embeddable interpreter**
  - MIR can execute code directly
  - Fits naturally with Enso’s dual execution model

- **C code generation**
  - Enables highly portable builds
  - Useful for constrained or unusual targets

- **Small and understandable**
  - Much simpler than LLVM
  - Easier to integrate tightly with Enso’s IR

MIR allows Enso to unify:
- compilation
- interpretation
- runtime execution

…within a single, cohesive system.

---

## Goals

- **Single, statically-linked binaries**
  - Minimal dynamic dependencies (Go-style deployment)

- **Zero-overhead Python**
  - `hello_world.py` should produce *identical object code* to `hello_world.c`

- **Freestanding targets**
  - A viable alternative to MicroPython

- **Dynamic + static execution**
  - AoT for performance
  - JIT for dynamic features
  - Interpreter for fallback paths

- **End-to-end optimization**
  - Standard library and packages compiled together

- **Long-term C API compatibility**
  - Enabled by CPython bytecode equivalence

---

## Non-Goals (for now)

- Full CPython C-extension compatibility on day one
- Perfect stdlib parity immediately
- Strict adherence to CPython implementation details where they conflict with performance

---

## Development Environment

In order to enable stable dev environments across hosts we rely on **nix**.  
We expect the [nix command and flake experimental features to be enabled](https://nixos.wiki/wiki/flakes).

Once nix is installed and configured you may start a development shell this way:

    nix develop

---

## Testing

    zig build test

or optionally filter tests from the CLI:

    zig build test -Dtest-filter='lex'

### Test runner reporting issues

Zig build will omit test results when they are cached:

    $ zig build test -Dtest-filter='ir' --summary all
    Build Summary: 3/3 steps succeeded; 9/10 tests passed; 1 skipped
    test success
    └─ run enso_tests 9 passed 1 skipped 1ms MaxRSS:3M
       └─ zig test enso_tests Debug native success 1s MaxRSS:227M

    # Now they are cached

    $ zig build test -Dtest-filter='ir' --summary all
    Build Summary: 3/3 steps succeeded
    test cached
    └─ run enso_tests cached
       └─ zig test enso_tests Debug native cached 5ms MaxRSS:50M

---

## Tour of the Source

- **lex.zig**
  - `Lexer{ .buffer = "..." }.next()`

- **parse.zig**
  - `Parser.init(allocator, "...")`
  - `ast_result = parser.parse()`

- **bytecode.zig**
  - `IrGen.init(allocator, intern_pool, ast)`
  - `instructions = ir_gen.generate()`

---

## Roadmap

- [ ] CPython bytecode parity
- [ ] MIR backend integration
- [ ] Interpreter ↔ compiler handoff
- [ ] Self-hosted Python runtime
- [ ] pip-distributed toolchain
- [ ] Freestanding runtime profile
- [ ] WASM backend (via alternative backend)
- [ ] SPIR-V experimentation

---

## Related Work & Inspiration

- CPython
- PyPy
- TruffleRuby – Chris Seaton
  https://www.youtube.com/watch?v=-iVh_8_J-Uo
- Rubinius
- [Natalie](https://natalie-lang.org)
- [MIR](https://github.com/vnmakarov/mir)
- [Zig](https://ziglang.org)

---

## License

TBD.

The project intends to remain **free software**, while carefully navigating the tradeoffs around commercial reuse and ecosystem sustainability.

> *Enso is a circle without beginning or end — a language that understands itself.*
