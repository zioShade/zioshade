#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Complex type conversion chain
void main() {
    // bool -> int -> float -> vec3
    bool b = uv.x > 0.5;
    int i = b ? 1 : 0;
    float f = float(i);
    vec3 v = vec3(f, f * 0.5, f * 0.25);
    
    // uint intermediate
    uint u = uint(f * 255.0);
    float back = float(u) / 255.0;
    
    vec3 col = v + vec3(back * 0.3);
    fragColor = vec4(col, 1.0);
}
