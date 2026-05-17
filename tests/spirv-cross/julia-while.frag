#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test while loop with multiple conditions
void main() {
    float x = uv.x * 2.0;
    float y = uv.y * 2.0;
    
    float a = x;
    float b = y;
    int count = 0;
    
    while (a * a + b * b < 4.0 && count < 20) {
        float new_a = a * a - b * b + x;
        b = 2.0 * a * b + y;
        a = new_a;
        count++;
    }
    
    float val = float(count) / 20.0;
    vec3 col = vec3(val, val * val, sqrt(val));
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
