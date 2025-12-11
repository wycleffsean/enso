![Enso Logo](https://cdn.vectorstock.com/i/thumbs/07/69/red-enso-zen-japanese-circle-brush-stroke-vector-44400769.jpg)

# Ensō 🐍
*A Python compiler–interpreter written in Zig*

Enso is an implementation of **Python in Zig** that treats **compilation and interpretation as two backends of the same system**.

Instead of a JIT-first architecture, Enso prioritizes **ahead-of-time compilation**, beginning with a **QBE backend**, while embedding an interpreter for the parts of a program that can only be resolved at runtime. The result is a system where Python code can be **partially evaluated**, **partially compiled**, and **partially interpreted**—all from a single, shared core representation.

The name *Enso* comes from the Zen circle, often associated with infinity, recursion, and self-reference. Like the ouroboros, Enso consumes itself:

> **Python is implemented in Python, which is compiled by Enso.**

---

## Table of Contents

- [Why Enso?](#why-enso)
- [Core Ideas](#core-ideas)
- [Architecture Overview](#architecture-overview)
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
- **PyPy**: brilliant research, but limited adoption due largely to C-extension compatibility

Enso takes a different path:

- Python is treated as a **compilable language first**
- Interpretation exists as a **fallback mechanism**, not the core execution model
- The **entire stack**—language, standard library, and packages—can be optimized end-to-end

This enables optimizations that resemble **whole-program compilation and LTO**, even for a dynamic language like Python.

---

## Core Ideas

### 1. One IR, Two Backends

Enso parses Python source into **bytecode-equivalent IR** that is *semantically identical* to CPython’s `dis` output:

```bash
python -m dis source.py
```


Every instruction in this IR can be:

- compiled (e.g. to QBE → native code), or
- interpreted (when runtime values prevent static resolution)

There is **no separate interpreter and compiler** — just different execution strategies over the same representation.

---

2. Partial Evaluation as the Primary Optimization

The first pass of a program is interpreted.
Any values discovered to be compile-time constants are partially applied, enabling subsequent compilation.

This allows Enso to:

- specialize aggressively
- eliminate dynamic overhead
- avoid JIT complexity entirely

---

3. Python Implemented in Python

Long-term, Enso aims to follow the [philosophy articulated by Chris Seaton](https://www.youtube.com/watch?v=-iVh_8_J-Uo) (TruffleRuby):

> Implement the language in itself, not in a foreign runtime.

This means:

- The Python standard library is written in Python
- Core runtime logic migrates out of Zig over time
- Zig becomes the substrate, not the language definition

---

## Architecture Overview

```
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
     └──► Compiler
            ├─ QBE → native (today)
            ├─ Zig backend (future)
            ├─ WASM (future)
            └─ SPIR-V (future)
```

At link time, the interpreter is **only included if needed**.

---

## Goals

- Single, statically-linked binaries
  - Minimal dynamic dependencies (Go-style deployment)
- Zero-overhead Python
  - hello_world.py should produce identical object code to hello_world.c
- Freestanding targets
  - A viable alternative to MicroPython
- Multiple backends
  - Native via QBE
  - WASM (via Zig backend)
  - SPIR-V for GPU / compute use-cases
- End-to-end optimization
  - Standard library and packages compiled together
- Long-term C API compatibility
  - Enabled by CPython bytecode equivalence

### Non-Goals (for now)

- JIT compilation
- Perfect CPython C-extension compatibility on day one
- Immediate parity with CPython’s full stdlib

---

## Development Environment


In order to enable stable dev environments across hosts we rely on nix.
We expect the [nix command and flake experimental features to be enabled](https://nixos.wiki/wiki/flakes).

Once nix is installed and configured you may start a development shell this way:

```sh
nix develop
```

---

## Testing

```sh
zig build test
```

or optionally filter tests from the CLI:

```sh
zig build test -Dtest-filter='lex'
```

### Test runner reporting issues

Zig build will omit test results when they are cached:

```
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
```

---

## Tour of the source

- lex.zig
  - `Lexer{ .buffer = "..." }#next()`
- parse.zig
  - `Parser.init(allocator, "...")`
  - `ast_result = parser.parse()``
- bytecode.zig
  - `IrGen.init(allocator, intern_pool, ast)`
  - `instructions = ir_gen.generate()`

---

## Roadmap

- [ ] CPython bytecode parity
- [ ] QBE backend stabilization
- [ ] Interpreter ↔ compiler handoff
- [ ] Self-hosted Python runtime
- [ ] Zig backend (WASM)
- [ ] Freestanding runtime profile
- [ ] SPIR-V experimentation
- [ ] pip-distributed toolchain

---

## Related Work & Inspiration

- CPython
- PyPy
- TruffleRuby – Chris Seaton - https://www.youtube.com/watch?v=-iVh_8_J-Uo
- Rubinius
- [Natalie](https://natalie-lang.org)
- [QBE](https://c9x.me/compile)
- [Zig](https://ziglang.org)

---

## License

TBD.

The project intends to remain free software, while carefully navigating the tradeoffs around commercial reuse and ecosystem sustainability.

> Enso is a circle without beginning or end — a language that understands itself.
