#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test OpVectorTimesScalar
void main() {
    vec3 v = vec3(uv.x, uv.y, uv.x * uv.y);
    float s = sin(uv.x * 3.14) * 2.0 + 0.5;
    
    vec3 scaled = v * s;
    vec3 divided = v / (s + 0.1);
    
    // Also test vec * mat
    mat2 m = mat2(0.5, -0.5, 0.5, 0.5);
    vec2 rotated = m * uv;
    
    vec3 col = scaled * 0.3 + divided * 0.2;
    col.xy += rotated;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
