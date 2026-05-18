#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Local array with expressions
void main() {
    float arr[3];
    arr[0] = uv.x;
    arr[1] = uv.y;
    arr[2] = uv.x * uv.y;
    
    float val = arr[2];
    fragColor = vec4(val, val, val, 1.0);
}
