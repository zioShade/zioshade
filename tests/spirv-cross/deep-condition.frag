#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Complex conditional chain
void main() {
    float x = uv.x;
    float y = uv.y;
    
    vec3 col;
    
    // Nested conditions with varying depth
    if (x < 0.2) {
        col = vec3(0.8, 0.2, 0.1);
    } else {
        if (x < 0.4) {
            col = vec3(0.2, 0.8, 0.1);
            if (y > 0.5) col *= 1.5;
        } else if (x < 0.6) {
            col = vec3(0.1, 0.2, 0.8);
            col *= sin(y * 3.14) * 0.5 + 0.5;
        } else if (x < 0.8) {
            col = vec3(0.8, 0.8, 0.1);
            for (int i = 0; i < 3; i++) {
                col += 0.05 * sin(y * float(i) * 3.14);
            }
        } else {
            col = vec3(0.8, 0.1, 0.8);
            col *= exp(-abs(y - 0.5) * 3.0);
        }
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
