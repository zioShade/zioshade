#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test floor/ceil/fract/mod roundtrip
void main() {
    float x = uv.x * 10.0;
    float y = uv.y * 10.0;
    
    float f = fract(x);
    float fl = floor(x);
    float c = ceil(x);
    float m = mod(x, 3.0);
    float r = round(x);
    
    float val = f + fl * 0.01 + c * 0.001;
    val = fract(val + m * 0.1 + r * 0.01);
    
    fragColor = vec4(val, uv.y, uv.x, 1.0);
}
