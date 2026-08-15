//! Single in-source spelling of the package version.
//!
//! build.zig.zon's `.version` is not importable from source code (the zon is
//! package-manager metadata), so the CLI reads it here. To keep the two from
//! drifting apart, `just check-version-sync` (tools/check_version_sync.py,
//! wired into the fmt CI job) fails whenever this constant and the zon
//! disagree. Bump BOTH together; the gate catches a forgotten half.
pub const version_string = "0.6.0";
