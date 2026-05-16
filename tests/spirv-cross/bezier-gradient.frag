#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Gradient through a curve
void main() {
    // Cubic bezier gradient
    float t = uv.y;
    float curve_x = 3.0 * t * t * (1.0 - t) + t * t * t;
    float curve_y = 3.0 * t * (1.0 - t) * (1.0 - t) * 0.5 + 3.0 * t * t * (1.0 - t) + t * t * t;
    
    float d = abs(uv.x - curve_x) * 5.0;
    float brightness = smoothstep(0.3, 0.0, d);
    
    vec3 col = vec3(t, 0.3, 1.0 - t) * brightness;
    fragColor = vec4(col, 1.0);
}
