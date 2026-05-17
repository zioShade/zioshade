#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test early return from main with atan2
void main() {
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    
    if (r > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    
    float angle = atan(p.y, p.x);
    float hue = angle / 6.28 + 0.5;
    
    vec3 col = vec3(
        abs(hue * 6.0 - 3.0) - 1.0,
        2.0 - abs(hue * 6.0 - 2.0),
        2.0 - abs(hue * 6.0 - 4.0)
    );
    col = clamp(col, 0.0, 1.0);
    col *= smoothstep(1.0, 0.5, r);
    
    fragColor = vec4(col, 1.0);
}
