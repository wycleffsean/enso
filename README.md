## Development environment

In order to enable stable dev environments across hosts we rely on nix.  We expect [nix command and flake experimental features to be enabled](https://nixos.wiki/wiki/flakes). Once nix is installed and configured you may start a development shell this way:

```
nix develop
```

## Testing

```
zig build test
```

or optionally filter tests from the cli

```
zig build test -Dtest-filter=lex'
```

### Test runner reporting issues

Zig build will omit test results when they are cached:

```
[sean@sean-Arch enso]$ zig build test -Dtest-filter='ir' --summary all
Build Summary: 3/3 steps succeeded; 9/10 tests passed; 1 skipped
test success
└─ run enso_tests 9 passed 1 skipped 1ms MaxRSS:3M
   └─ zig test enso_tests Debug native success 1s MaxRSS:227M

# Now they are cached

[sean@sean-Arch enso]$ zig build test -Dtest-filter='ir' --summary all
Build Summary: 3/3 steps succeeded
test cached
└─ run enso_tests cached
   └─ zig test enso_tests Debug native cached 5ms MaxRSS:50M
```

# Tour of the source

- lex.zig
  - `Lexer{ .buffer = "..." }#next()`
- parse.zig
  - `Parser.init(allocator, "...")`
  - `ast_result = parser.parse()``
- bytecode.zig
  - `IrGen.init(allocator, intern_pool, ast)`
  - `instructions = ir_gen.generate()`
