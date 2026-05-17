#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test many small functions calling each other
float twice(float x) { return x * 2.0; }
float halve(float x) { return x * 0.5; }
float add_one(float x) { return x + 1.0; }

float pipeline(float x) {
    return halve(twice(add_one(x)));
}

void main() {
    float a = pipeline(uv.x);
    float b = pipeline(uv.y);
    float c = pipeline(uv.x + uv.y);
    
    vec3 col = vec3(a * 0.5, b * 0.5, c * 0.25);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
