// Tests: dynamic double-index into a LOCAL matrix — m[i][j] with BOTH indices
// dynamic in one chained expression. The inner m[i] lowers to an OpAccessChain
// (pointer-to-column); the outer [j] must LOAD that column before the dynamic
// OpVectorExtractDynamic. Regression guard for #170 (frontend emitted
// VectorExtractDynamic on a pointer → invalid SPIR-V / dangling-ID after DCE).
#version 450
layout(location = 0) in vec3 a;
layout(location = 1) in vec3 b;
layout(location = 2) in vec3 c;
layout(location = 3) flat in int i;
layout(location = 4) flat in int j;
layout(location = 0) out vec4 o;

void main() {
    mat3 m = mat3(a, b, c);
    o = vec4(m[i][j]);
}
