#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Quilez-style 2D SDF operations
float sdCircle(vec2 p, float r) { return length(p) - r; }
float sdBox(vec2 p, vec2 b) { vec2 d = abs(p) - b; return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0); }

void main() {
    vec2 p = uv * 4.0 - 2.0;
    
    float d1 = sdCircle(p - vec2(-0.8, 0.0), 0.7);
    float d2 = sdBox(p - vec2(0.8, 0.0), vec2(0.5));
    
    // Smooth union
    float k = 0.3;
    float h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    float d = mix(d2, d1, h) - k * h * (1.0 - h);
    
    float fill = 1.0 - smoothstep(0.0, 0.02, d);
    
    vec3 col = vec3(0.05);
    col += vec3(0.6, 0.3, 0.8) * fill;
    col += vec3(0.3, 0.5, 0.6) * (1.0 - smoothstep(0.0, 0.05, abs(d))) * 0.5;
    
    fragColor = vec4(col, 1.0);
}
