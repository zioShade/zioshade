// Tests: module-scope initializer that is NOT a compile-time constant (it
// reads a uniform and calls a helper). GLSL executes such initializers before
// main, so the lowering must emit either an OpVariable initializer or a store
// in the entry prologue that dominates every read. Regression guard for the
// zioshade-kgt class (uniform-derived global initializers silently dropped:
// the Private OpVariable carried no initializer and no store, every backend
// read zeroes; found by rendering the wintty gallery on WARP vs SPIRV-Cross).
// The conformance runner also runs src/spirv_lint.zig's globalInitDominance
// over this fixture's emitted SPIR-V, so the dropped-initializer shape fails
// the gate even though the module still passes spirv-val.
#version 450
layout(std140, binding = 1) uniform Globals {
    vec4 iCurrentCursorColor;
};
layout(location = 0) out vec4 fragColor;

vec3 sRGBToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)),
               step(vec3(0.04045), c));
}

// Uniform-derived: cannot const-fold; must survive as a runtime init.
vec4 TRAIL_COLOR = vec4(sRGBToLinear(iCurrentCursorColor.rgb),
                        iCurrentCursorColor.a);
const float TAU = 6.28318530;

void main() {
    vec2 dir = vec2(cos(TAU * 0.125), sin(TAU * 0.125));
    float fade = clamp(dir.x + 0.5, 0.0, 1.0);
    fragColor = TRAIL_COLOR * fade;
}
