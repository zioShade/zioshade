#version 450
// Regression guard: a constant array LUT (OpConstantComposite of array type)
// must emit `array<f32, N>(...)` in WGSL, not `array<float, N>(...)` — the GLSL
// scalar name `float` would leak as a bare identifier that naga rejects
// ("no definition in scope for identifier: float").
layout(location = 0) flat in int idx;
layout(location = 0) out vec4 o;

void main() {
    float lut[5] = float[](1.0, 2.0, 3.0, 4.0, 5.0);
    int i = clamp(idx, 0, 4);
    o = vec4(lut[i], lut[4 - i], 0.0, 1.0);
}
