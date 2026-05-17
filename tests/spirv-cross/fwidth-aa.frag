#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test fwidth and flat interpolation qualifier approximation
void main() {
    // Gradient field
    float val = sin(uv.x * 20.0) * cos(uv.y * 20.0);
    
    // Analyze gradient
    float fw = fwidth(val);
    
    // Anti-alias based on fwidth
    float edge = smoothstep(fw, -fw, abs(val));
    
    vec3 col = mix(vec3(0.1, 0.1, 0.2), vec3(0.9, 0.7, 0.3), edge);
    fragColor = vec4(col, 1.0);
}
