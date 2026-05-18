#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Minimal local array test
void main() {
    float arr[3];
    arr[0] = 0.5;
    arr[1] = 0.3;
    arr[2] = 0.7;
    
    float val = arr[1];
    fragColor = vec4(val, val, val, 1.0);
}
