#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple function overloads (different param counts)
float process(float x) { return x * 2.0; }
float process(float x, float y) { return x + y; }
vec3 process(vec3 v) { return v * vec3(1.0, 2.0, 3.0); }

void main() {
    float a = process(uv.x);
    float b = process(uv.x, uv.y);
    vec3 c = process(vec3(uv, 0.5));
    
    vec3 col = vec3(a, b, 0.0) + c * 0.1;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
