// SPDX-License-Identifier: MIT OR Apache-2.0
//! Structural SPIR-V lints for silent-wrong bug classes that no validity
//! oracle can see: the emitted module is VALID (spirv-val passes, every
//! backend compiles it), it just computes the wrong thing.
//!
//! These run in the conformance runner over every fixture's emitted SPIR-V,
//! so a regression of a closed bug class fails `just ci` even when the
//! output still validates.

/// Opcodes the lints inspect (numbering per the SPIR-V core grammar). The
/// walkers below skip every other opcode by its declared word count, so an
/// unknown instruction never derails the scan.
const Op = struct {
    const entry_point = 15;
    const function = 54;
    const function_end = 56;
    const variable = 59;
    const load = 61;
    const store = 62;
    const copy_memory = 63;
    const access_chain = 65;
    const in_bounds_access_chain = 66;
};

const storage_private = 6;

/// SPIR-V magic word, little-endian layout (0x07230203 as u32).
const magic: u32 = 0x0723_0203;

pub const GlobalInitViolation = struct {
    /// The Private OpVariable that was read before any initializer reached it.
    variable_id: u32,
};

/// Cap on how many globals / derived pointers a module may have before the
/// lint goes silent (returns null) instead of tracking incompletely. Silence
/// can hide a bug; a wrong report would cry wolf, so silence is chosen.
const max_globals = 64;
const max_derived = 256;

/// zioshade-kgt: a GLSL module-scope initializer that is not a compile-time
/// constant (it reads a uniform or calls a helper, e.g. the wintty cursor
/// shaders' `vec4 TRAIL_COLOR = vec4(sRGBToLinear(iCurrentCursorColor.rgb),
/// iCurrentCursorColor.a);`) must reach SPIR-V one of two ways:
///
///   * the OpVariable carries an Initializer operand, or
///   * the entry function stores the value to the variable BEFORE any read.
///
/// The original bug: the const-fold pass rolled non-constant initializers
/// back and nothing re-emitted them, so the Private OpVariable had neither an
/// initializer nor a store and every backend read zeroes (the cursor trail
/// rendered black on a dark terminal). The module still validated, so no
/// compile-only gate could see it.
///
/// This lint walks the emitted SPIR-V directly (no IR, no oracle): pass 1
/// collects the entry point and the global Private variables lacking an
/// Initializer operand; pass 2 walks every function's instructions in
/// emission order and reports two violation shapes:
///
///   A. entry-function read (OpLoad / OpCopyMemory source, direct or through
///      an OpAccessChain view) that no preceding store in that linear order
///      dominates. Emission order is exactly SPIR-V's structured-control-flow
///      order for a store hoisted to the entry prologue (the lowering this
///      lint guards); a store buried inside a branch that merely TEXTUALLY
///      precedes a later read also passes here, which errs permissive.
///   B. a Private variable with no Initializer that is READ somewhere in the
///      module but NEVER written anywhere (no OpStore, no OpCopyMemory
///      target, direct or access-chain). This is the exact dropped-initializer
///      shape the historical bug produced: the real wintty shaders read the
///      global inside mainImage (a HELPER function, not the entry point), so
///      a dominance check scoped to the entry function alone cannot see it;
///      never-written-anywhere can. (Reads of globals written only inside
///      branches are not reported: that is the same permissive-by-design
///      approximation as A, never a false positive.)
///
/// Returns null when there is nothing to check, the module is malformed, or
/// tracking capacity is exceeded.
pub fn globalInitDominance(words: []const u32) ?GlobalInitViolation {
    if (words.len < 5) return null;
    if (words[0] != magic) return null;

    // Pass 1: global section (everything before the first OpFunction).
    var entry: ?u32 = null;
    var gids: [max_globals]u32 = undefined;
    var ginit: [max_globals]bool = undefined;
    var n_globals: usize = 0;
    var overflow = false;
    var i: usize = 5;
    while (i < words.len) {
        const w = words[i];
        const count: usize = w >> 16;
        const op = w & 0xffff;
        if (count == 0 or i + count > words.len) return null; // malformed: silent
        switch (op) {
            Op.entry_point => {
                if (entry == null and count >= 4) entry = words[i + 2];
            },
            Op.function => break, // functions start; globals are done
            Op.variable => {
                // [result_type, result, storage, initializer?]
                if (count >= 4 and words[i + 3] == storage_private) {
                    if (n_globals < max_globals) {
                        gids[n_globals] = words[i + 2];
                        ginit[n_globals] = count >= 5;
                        n_globals += 1;
                    } else {
                        overflow = true;
                    }
                }
            },
            else => {},
        }
        i += count;
    }
    if (n_globals == 0 or overflow) return null;
    if (entry == null) return null;

    // Pass 2: all function bodies. Rule A gates on the entry function; rule B
    // needs every function (helper reads are the historical shape).
    var derived_ids: [max_derived]u32 = undefined;
    var derived_g: [max_derived]usize = undefined;
    var n_derived: usize = 0;
    var gread: [max_globals]bool = undefined;
    for (&gread) |*r| r.* = false;

    // Resolve a pointer id to a tracked-global INDEX; OpAccessChain views
    // resolve to their base global (chains of chains follow hop by hop).
    const resolveIndex = struct {
        fn f(
            id: u32,
            gids_: []const u32,
            n_globals_: usize,
            derived_ids_: []const u32,
            derived_g_: []const usize,
            n_derived_: usize,
        ) ?usize {
            var cur = id;
            var hops: usize = 0;
            while (hops < max_derived) : (hops += 1) {
                for (gids_[0..n_globals_], 0..) |gid, k| {
                    if (gid == cur) return k;
                }
                var found = false;
                for (derived_ids_[0..n_derived_], 0..) |did, j| {
                    if (did == cur) {
                        cur = gids_[derived_g_[j]];
                        found = true;
                        break;
                    }
                }
                if (!found) return null;
            }
            return null;
        }
    }.f;

    var in_entry = false;
    while (i < words.len) {
        const w = words[i];
        const count: usize = w >> 16;
        const op = w & 0xffff;
        if (count == 0 or i + count > words.len) return null;
        switch (op) {
            Op.function => {
                in_entry = count >= 3 and words[i + 2] == entry.?;
            },
            Op.function_end => {
                in_entry = false;
            },
            Op.access_chain, Op.in_bounds_access_chain => {
                // [result_type, result, base, indexes...]; ids are unique
                // module-wide, so derived views can be tracked across
                // functions even though each view lives in one function.
                if (count >= 4) {
                    const result = words[i + 2];
                    const base = words[i + 3];
                    if (resolveIndex(base, &gids, n_globals, &derived_ids, &derived_g, n_derived)) |k| {
                        if (n_derived < max_derived) {
                            derived_ids[n_derived] = result;
                            derived_g[n_derived] = k;
                            n_derived += 1;
                        }
                    }
                }
            },
            Op.store => {
                // [pointer, object]
                if (count >= 3) {
                    if (resolveIndex(words[i + 1], &gids, n_globals, &derived_ids, &derived_g, n_derived)) |k| {
                        ginit[k] = true;
                    }
                }
            },
            Op.copy_memory => {
                // [target, source]: writes target, reads source.
                if (count >= 3) {
                    if (resolveIndex(words[i + 1], &gids, n_globals, &derived_ids, &derived_g, n_derived)) |k| {
                        ginit[k] = true;
                    }
                    if (resolveIndex(words[i + 2], &gids, n_globals, &derived_ids, &derived_g, n_derived)) |k| {
                        gread[k] = true;
                        if (in_entry and !ginit[k]) return .{ .variable_id = gids[k] };
                    }
                }
            },
            Op.load => {
                // [result_type, result, pointer, memory operands...]
                if (count >= 4) {
                    if (resolveIndex(words[i + 3], &gids, n_globals, &derived_ids, &derived_g, n_derived)) |k| {
                        gread[k] = true;
                        if (in_entry and !ginit[k]) return .{ .variable_id = gids[k] };
                    }
                }
            },
            else => {},
        }
        i += count;
    }

    // Rule B: read somewhere, never written anywhere, no Initializer operand.
    for (gread[0..n_globals], 0..) |read, k| {
        if (read and !ginit[k]) return .{ .variable_id = gids[k] };
    }
    return null;
}
