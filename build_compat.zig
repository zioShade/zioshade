//! Build-system compatibility shims across supported Zig versions.
//!
//! The build API churns more than the language, so version-divergent build.zig
//! calls live here, selected by CAPABILITY DETECTION (`@hasDecl`/`@hasField`)
//! rather than version numbers so newer releases work untouched. Each shim
//! carries a `COMPAT(x.y)` marker noting when it can be removed once the floor
//! moves past that version. See src/compat.zig for the runtime counterpart and
//! the hard floor (Zig 0.15.2).

const std = @import("std");

/// Read an environment variable, caller-owned, or null if unset or unreadable.
///
/// Zig 0.16 removed `std.process.getEnvVarOwned` (env access moved behind the
/// new `std.Io` model). This is only used for the optional `lib-bench` recipe's
/// `$VULKAN_SDK` autodetect, which already falls back to `-Dvulkan-sdk` or a
/// default, so on 0.16+ we degrade to null rather than pull an Io context into
/// build.zig. COMPAT(0.15): revisit if 0.16+ env autodetect becomes worth wiring.
pub fn getEnvVarOwned(alloc: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (comptime @hasDecl(std.process, "getEnvVarOwned")) {
        return std.process.getEnvVarOwned(alloc, name) catch null;
    } else {
        return null;
    }
}
