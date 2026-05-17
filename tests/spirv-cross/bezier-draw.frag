#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Bezier curve drawing
void main() {
    vec2 p0 = vec2(0.1, 0.2);
    vec2 p1 = vec2(0.5, 0.9);
    vec2 p2 = vec2(0.9, 0.2);
    
    float min_d = 1.0;
    for (int i = 0; i <= 32; i++) {
        float t = float(i) / 32.0;
        vec2 pos = (1.0 - t) * (1.0 - t) * p0 + 2.0 * (1.0 - t) * t * p1 + t * t * p2;
        float d = length(uv - pos);
        min_d = min(min_d, d);
    }
    
    float curve = smoothstep(0.02, 0.0, min_d);
    vec3 col = mix(vec3(0.05), vec3(0.3, 0.7, 1.0), curve);
    
    fragColor = vec4(col, 1.0);
}
