#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test matrix column access and scalar ops
void main() {
    mat3 m = mat3(
        1.0, 2.0, 3.0,
        4.0, 5.0, 6.0,
        7.0, 8.0, 9.0
    );
    
    // Column access
    vec3 c0 = m[0];
    vec3 c1 = m[1];
    vec3 c2 = m[2];
    
    // Scale columns by UV
    mat3 scaled = mat3(c0 * uv.x, c1 * uv.y, c2 * (uv.x + uv.y));
    
    // Transform a point
    vec3 v = vec3(1.0, 0.0, 0.0);
    vec3 result = scaled * v;
    
    fragColor = vec4(clamp(result / 10.0, 0.0, 1.0), 1.0);
}
