#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test complex conditional chain with float operations
void main() {
    float r = length(uv - 0.5);
    float a = atan(uv.y - 0.5, uv.x - 0.5);
    
    vec3 col = vec3(0.0);
    
    float segments = 8.0;
    float seg = floor(a / 6.28318 * segments + segments * 0.5);
    
    for (int i = 0; i < 8; i++) {
        if (seg == float(i)) {
            float t = float(i) / 8.0;
            col = vec3(t, 1.0 - t, sin(t * 6.28) * 0.5 + 0.5);
            break;
        }
    }
    
    col *= smoothstep(0.5, 0.1, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
