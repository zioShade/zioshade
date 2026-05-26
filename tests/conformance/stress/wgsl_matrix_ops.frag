// Test: complex matrix operations
#version 450

layout(binding = 0) uniform Matrices {
    mat4 model;
    mat4 view;
    mat4 projection;
};

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 pos = vec4(gl_FragCoord.xy / vec2(800.0, 600.0), 0.0, 1.0);
    
    mat4 mv = view * model;
    mat4 mvp = projection * mv;
    vec4 transformed = mvp * pos;
    
    // Matrix column access
    vec4 col0 = mvp[0];
    vec4 col1 = mvp[1];
    
    // Transpose
    mat4 t = transpose(mvp);
    
    // Determinant
    float d = determinant(mvp);
    
    // Inverse
    mat4 inv = inverse(mvp);
    vec4 back = inv * transformed;
    
    fragColor = vec4(col0.xy + col1.zw, d, back.z);
}
