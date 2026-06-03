#version 310 es
// Regression for the 2D-array function-parameter bug class (fixed in #46 / 3c52c0ac).
// Two entangled bugs this fixture guards against:
//   BUG 1 (parser): parseFunctionDecl consumed only ONE [N] dimension after a
//     parameter name, so a 2D-array param like `vec4 v[3][2]` parsed `[3]` then
//     failed on `[2]`, silently dropping the whole function via synchronize() ->
//     the call site threw UndeclaredIdentifier.
//   BUG 2 (optimizer): a var_decl with an array initializer did not populate
//     load_cache, so constStoreForward forwarded an id already consumed by the
//     composite_construct argument -> a dangling %id (OpCompositeExtract of an
//     undefined result) in the OPTIMIZED SPIR-V.
// Mirrors tests/spirv-cross/composite-construct.comp's specific mix (array-var
// assignment + array vars into a 2D-array constructor + struct-with-array-member
// constructor), as a fragment shader for the stress suite. Reads from a uniform
// and writes every value into fragColor so the store-forward constructs are not
// dead-code-eliminated.
// Coverage note: BUG 1 is a front-end (parse) property — the 2D-array param types
// are visible in the unoptimized SPIR-V regardless of how the body folds. BUG 2 is
// what must survive into the OPTIMIZED SPIR-V, which is why the values feeding the
// summe()/Composite constructors come from the uniform (unfoldable) rather than
// from constants.
precision highp float;

layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform U {
    vec4 seedA;
    vec4 seedB;
};

struct Composite {
    vec4 a[2];
    vec4 b[2];
};

// 2D-array (array-of-arrays) function parameter — BUG 1 parse target (vec4[3][2]).
vec4 summe(vec4 values[3][2]) {
    return values[0][0] + values[2][1] + values[0][1] + values[1][0];
}

// float[2][3] param shape — the brief's minimal repro, different dim order.
float pick(float v[2][3]) {
    return v[0][0] + v[1][2];
}

void main() {
    vec4 values[2] = vec4[](seedA, seedB);
    vec4 const_values[2] = vec4[](vec4(10.0), vec4(30.0));
    vec4 copy_values[2];
    copy_values = const_values;        // array-variable assignment
    vec4 copy_values2[2] = values;     // array copy-initialization

    // array vars passed into a 2D-array constructor (store-forward trigger).
    vec4 s = summe(vec4[][](values, copy_values, copy_values2));

    // struct-with-array-member constructor built from array vars.
    Composite c = Composite(values, copy_values);

    float aoa[2][3] = float[][](float[](1.0, 1.0, 1.0), float[](2.0, 2.0, 2.0));
    float p = pick(aoa);

    fragColor = s + c.a[0] + c.b[1] + vec4(p);
}
