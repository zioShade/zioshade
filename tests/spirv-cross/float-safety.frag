#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test IEEE float edge cases
void main() {
    float a = uv.x;
    float b = uv.y;
    
    // Test infinity-like patterns
    float big = 1.0 / (a * a + 0.01);
    float small = a * a + 0.01;
    
    // Test NaN-avoidance
    float safe_sqrt = sqrt(max(a, 0.0));
    float safe_log = log(max(a, 0.001));
    float safe_acos = acos(clamp(b, -1.0, 1.0));
    
    vec3 col = vec3(
        clamp(safe_sqrt, 0.0, 1.0),
        clamp(safe_log * 0.2 + 0.5, 0.0, 1.0),
        clamp(safe_acos / 3.14, 0.0, 1.0)
    );
    
    fragColor = vec4(col, 1.0);
}
