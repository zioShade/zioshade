#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test larger local array
void main() {
    float arr[5];
    arr[0] = uv.x;
    arr[1] = uv.y;
    arr[2] = uv.x * uv.y;
    arr[3] = uv.x + uv.y;
    arr[4] = uv.x - uv.y;
    
    // Sum the array
    float sum = arr[0] + arr[1] + arr[2] + arr[3] + arr[4];
    float val = clamp(sum * 0.2, 0.0, 1.0);
    fragColor = vec4(val, val, val, 1.0);
}
