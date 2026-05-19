#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test wave interference pattern (two source)
void main() {
    vec2 p = uv;
    
    // Two point sources
    vec2 s1 = vec2(0.3, 0.5);
    vec2 s2 = vec2(0.7, 0.5);
    
    float d1 = length(p - s1);
    float d2 = length(p - s2);
    
    // Wave from each source
    float freq = 60.0;
    float wave1 = sin(d1 * freq);
    float wave2 = sin(d2 * freq);
    
    // Superposition
    float superpos = (wave1 + wave2) * 0.5;
    
    // Map to color: blue (destructive) to cyan (constructive)
    float t = superpos * 0.5 + 0.5;
    vec3 destructive = vec3(0.0, 0.02, 0.1);
    vec3 constructive = vec3(0.1, 0.8, 1.0);
    vec3 col = mix(destructive, constructive, t);
    
    // Source markers
    float src1 = smoothstep(0.015, 0.01, length(p - s1));
    float src2 = smoothstep(0.015, 0.01, length(p - s2));
    col = mix(col, vec3(1.0, 0.3, 0.1), max(src1, src2));
    
    // Circular wave fronts (faint rings)
    float rings1 = smoothstep(0.01, 0.0, abs(fract(d1 * freq / 6.2832) - 0.5)) * 0.1;
    float rings2 = smoothstep(0.01, 0.0, abs(fract(d2 * freq / 6.2832) - 0.5)) * 0.1;
    col += (rings1 + rings2) * vec3(0.3, 0.5, 0.7);
    
    // Nodal lines (where destructive interference occurs)
    float nodal = smoothstep(0.05, 0.0, abs(superpos));
    col += nodal * vec3(0.05, 0.05, 0.15) * 0.5;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
