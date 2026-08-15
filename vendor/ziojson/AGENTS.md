# ziojson

## Overview

Small JSON text helpers for Zig. Three public functions and no allocator:
`tokenize`, `findKey`, `isValid`. It does not parse JSON into a tree and it
does not extend std.json.

## Project Structure

```
src/
  ziojson.zig    - Main library source
examples/
  example.zig    - Runnable example
build.zig        - Build configuration
```

## Commands

```bash
zig build test          # Run tests
zig build run-example   # Run the example
zig build               # Build the library
```

## Architecture

Single-file library with no external dependencies. All public symbols have doc comments.

## Testing

Tests are inline in `src/ziojson.zig`. Run with `zig build test`.
