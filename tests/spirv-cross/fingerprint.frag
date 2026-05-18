#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test fingerprint ridge pattern
void main() {
    vec2 p = uv - 0.5;
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Ridge pattern: modulated concentric ovals
    float ridge_freq = 35.0;
    float oval_r = length(p * vec2(1.2, 0.9));
    
    // Slight twist for realistic look
    float twist = a * 0.3 * smoothstep(0.4, 0.0, r);
    float ridges = sin((oval_r + twist) * ridge_freq) * 0.5 + 0.5;
    
    // Whorl center (spiral)
    float spiral = a * 2.0 / 6.2832 + oval_r * 5.0;
    float center_ridges = sin(spiral * ridge_freq * 0.3) * 0.5 + 0.5;
    
    // Blend between whorl center and outer ridges
    float center_blend = smoothstep(0.1, 0.2, r);
    float pattern = mix(center_ridges, ridges, center_blend);
    
    // Ink darkness: dark on ridges, light in valleys
    float ink = smoothstep(0.5, 0.55, pattern);
    
    // Pressure variation (lighter at edges)
    float pressure = smoothstep(0.45, 0.2, r);
    
    // Finger oval shape
    float finger = smoothstep(0.42, 0.38, r);
    
    vec3 ink_col = vec3(0.15, 0.12, 0.1);
    vec3 paper = vec3(0.95, 0.92, 0.88);
    
    vec3 col = mix(ink_col, paper, 1.0 - ink * pressure * finger);
    
    // Smudge at edges
    float smudge = smoothstep(0.35, 0.42, r) * finger * 0.1;
    col = mix(col, ink_col * 0.5 + paper * 0.5, smudge);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
