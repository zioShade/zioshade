#version 450
// Regression for #173 item 2: the SIZED multi-dimensional array constructor
// `float[2][3](...)` parsed its bracket dims inner-first, so the constructor's
// type came out with swapped dimensions vs the (correctly built) declared type.
// That mismatch made `const float m[2][3] = float[2][3](...)` a type error (and,
// when folded, an OpConstantComposite whose constituent count did not match its
// OpTypeArray length — spirv-val "Constituent count does not match NumElements").
// The fix collects all bracket dims then reverse-wraps outermost-to-innermost,
// mirroring the declaration-side logic. Runtime-indexed so the values survive DCE
// and the OpConstantComposite array is actually materialized + spirv-val-checked.
layout(location = 0) out vec4 FragColor;

void main() {
    const float m[2][3] = float[2][3](float[3](1.0, 2.0, 3.0), float[3](4.0, 5.0, 6.0));
    int i = int(gl_FragCoord.x) & 1;
    int j = int(gl_FragCoord.y) % 3;
    FragColor = vec4(m[i][j]);
}
