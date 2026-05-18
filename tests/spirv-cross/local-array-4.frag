#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test 4-element local array
void main() {
    float arr[4];
    arr[0] = uv.x;
    arr[1] = uv.y;
    arr[2] = uv.x * uv.y;
    arr[3] = uv.x + uv.y;
    
    float sum = arr[0] + arr[1] + arr[2] + arr[3];
    float val = clamp(sum * 0.25, 0.0, 1.0);
    fragColor = vec4(val, val, val, 1.0);
}
