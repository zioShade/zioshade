#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Truchet tile pattern
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Random orientation per tile
    float h = step(0.5, hash(id));
    
    // Arc distance based on orientation
    vec2 center = mix(vec2(0.0, 0.0), vec2(1.0, 1.0), h);
    float d1 = abs(length(fp - center) - 0.5);
    
    vec2 center2 = mix(vec2(1.0, 0.0), vec2(0.0, 1.0), h);
    float d2 = abs(length(fp - center2) - 0.5);
    
    float arc = min(d1, d2);
    float line = smoothstep(0.06, 0.03, arc);
    
    vec3 bg = vec3(0.08);
    vec3 fg = vec3(0.7, 0.5, 0.3);
    
    vec3 col = mix(bg, fg, line);
    fragColor = vec4(col, 1.0);
}
