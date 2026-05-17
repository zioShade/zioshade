#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test atan2 with various quadrant combinations
void main() {
    vec2 a = uv * 4.0 - 2.0;
    
    // atan2 in all 4 quadrants
    float angle = atan(a.y, a.x);
    
    // Map angle to color wheel
    float hue = angle / 6.28318 + 0.5;
    
    // HSV to RGB (simplified)
    float h = fract(hue) * 6.0;
    float f = fract(h);
    vec3 col;
    if (h < 1.0) col = vec3(1.0, f, 0.0);
    else if (h < 2.0) col = vec3(1.0 - f, 1.0, 0.0);
    else if (h < 3.0) col = vec3(0.0, 1.0, f);
    else if (h < 4.0) col = vec3(0.0, 1.0 - f, 1.0);
    else if (h < 5.0) col = vec3(f, 0.0, 1.0);
    else col = vec3(1.0, 0.0, 1.0 - f);
    
    // Fade with distance
    float d = length(a) * 0.5;
    col *= smoothstep(1.5, 0.2, d);
    
    fragColor = vec4(col, 1.0);
}
