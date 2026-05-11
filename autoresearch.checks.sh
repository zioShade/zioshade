#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# Correctness checks: run all test suites (suppress success output, only show errors)

# Core tests
mise exec -- zig test src/root.zig 2>&1 | tail -5

# HLSL tests (751 tests)
mise exec -- zig build test-hlsl 2>&1 | grep "failed\|leaked" || true

# GLSL tests (91 tests)
mise exec -- zig build test-glsl 2>&1 | grep "failed\|leaked" || true

# MSL tests (39 tests)
mise exec -- zig build test-msl 2>&1 | grep "failed\|leaked" || true
