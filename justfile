# glslpp build recipes

# default: build and test
default: test

# build the library
build:
    zig build

# run all tests
test:
    zig build test

# run tests with verbose output
test-verbose:
    zig build test --summary all

# clean build artifacts
clean:
    rm -rf zig-out zig-cache

# build in release mode
release:
    zig build -Doptimize=ReleaseFast

# check compilation without building
check:
    zig build 2>&1 | head -1

# run a specific test by name filter
filter name:
    zig build test -Dtest-filter={{name}}
