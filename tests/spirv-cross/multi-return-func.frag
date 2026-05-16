#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple return paths from a function
float getValue(vec2 p) {
    if (p.x > 0.7) return p.x * 3.0;
    if (p.x > 0.4) return p.y * 2.0;
    if (p.x > 0.2) return p.x + p.y;
    return p.y * p.y;
}

void main() {
    float v = getValue(uv);
    vec3 col = vec3(v, v * 0.7, v * 0.4);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
