#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test kaleidoscope pattern
void main() {
    vec2 p = uv - 0.5;
    float a = atan(p.y, p.x);
    float r = length(p);
    
    // Fold into 6 segments
    float segments = 6.0;
    float seg_angle = 6.28318 / segments;
    float folded_a = mod(a, seg_angle);
    folded_a = min(folded_a, seg_angle - folded_a);
    
    // Reconstruct folded position
    vec2 folded = vec2(cos(folded_a), sin(folded_a)) * r;
    
    // Pattern in folded space
    float pattern = sin(folded.x * 20.0) * sin(folded.y * 20.0);
    pattern = pattern * 0.5 + 0.5;
    
    vec3 col = vec3(pattern, pattern * folded_a / seg_angle, pattern * r * 2.0);
    col *= smoothstep(0.5, 0.1, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
