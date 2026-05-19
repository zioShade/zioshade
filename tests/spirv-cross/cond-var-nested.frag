#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nested conditional variable mutation
void main() {
    float val = 0.5;
    
    if (uv.x > 0.3) {
        val += 0.2;
        if (uv.y > 0.5) {
            val *= 1.5;
        }
    } else {
        val -= 0.1;
    }
    
    vec3 col = vec3(val, val * 0.7, val * 0.3);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
