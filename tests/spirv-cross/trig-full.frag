#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test sin/cos/tan with various inputs
void main() {
    float x = uv.x * 6.28;
    float y = uv.y * 3.14;
    
    float s = sin(x);
    float c = cos(x);
    float t = tan(y * 0.5);
    
    // Inverse trig
    float as = asin(s) / 3.14;
    float ac = acos(c) / 3.14;
    float at = atan(t) / 1.57;
    
    vec3 col = vec3(s * 0.5 + 0.5, at * 0.5 + 0.5, c * 0.5 + 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
