#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test gl_FrontFacing builtin (via alternative - using a varying)
void main() {
    // Test conditional execution with discard
    float d = length(uv - 0.5);
    
    if (d > 0.45) {
        // Outside circle - transparent
        fragColor = vec4(0.1, 0.1, 0.1, 1.0);
        return;
    }
    
    // Inside circle - color based on angle
    float angle = atan(uv.y - 0.5, uv.x - 0.5);
    float r = sin(angle * 3.0) * 0.5 + 0.5;
    float g = sin(angle * 5.0 + 1.0) * 0.5 + 0.5;
    float b = sin(angle * 7.0 + 2.0) * 0.5 + 0.5;
    
    fragColor = vec4(r, g, b, 1.0);
}
