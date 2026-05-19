#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test electromagnetic wave (E and B fields)
void main() {
    vec3 col = vec3(0.02, 0.02, 0.05);
    
    // Propagation along x-axis
    float x = uv.x;
    float phase = x * 20.0;
    
    // E-field (vertical, red)
    float e_amp = sin(phase) * 0.15;
    float e_center = 0.5;
    float e_y = e_center + e_amp;
    float e_trace = smoothstep(0.006, 0.002, abs(uv.y - e_y));
    col += e_trace * vec3(0.9, 0.2, 0.15);
    
    // E-field glow
    float e_glow = exp(-abs(uv.y - e_y) * 30.0) * 0.03;
    col += e_glow * vec3(0.5, 0.1, 0.05);
    
    // B-field (horizontal, going into/out of screen — shown as depth perspective)
    float b_amp = cos(phase) * 0.12;
    float b_center = 0.5;
    float b_y = b_center + b_amp;
    float b_trace = smoothstep(0.005, 0.002, abs(uv.y - b_y));
    col += b_trace * vec3(0.15, 0.3, 0.9);
    
    // B-field glow
    float b_glow = exp(-abs(uv.y - b_y) * 30.0) * 0.02;
    col += b_glow * vec3(0.05, 0.1, 0.5);
    
    // Propagation axis
    float axis = smoothstep(0.003, 0.001, abs(uv.y - 0.5));
    col += axis * vec3(0.2, 0.2, 0.25);
    
    // Wavelength markers
    float lambda_markers = smoothstep(0.005, 0.002, abs(fract(uv.x * 3.183) - 0.5)) * smoothstep(0.495, 0.5, uv.y) * smoothstep(0.52, 0.505, uv.y);
    col += lambda_markers * vec3(0.3);
    
    // Labels (simplified: colored dots)
    float e_dot = smoothstep(0.012, 0.008, length(uv - vec2(0.08, 0.85)));
    col = mix(col, vec3(0.9, 0.2, 0.15), e_dot);
    float b_dot = smoothstep(0.012, 0.008, length(uv - vec2(0.08, 0.75)));
    col = mix(col, vec3(0.15, 0.3, 0.9), b_dot);
    
    // Direction arrow (propagation direction)
    float arrow_body = smoothstep(0.003, 0.001, abs(uv.y - 0.92)) * step(0.15, uv.x) * step(uv.x, 0.35);
    float arrow_head = smoothstep(0.01, 0.005, length(uv - vec2(0.35, 0.92)) - 0.01) * step(0.0, uv.x - 0.33);
    col += (arrow_body + arrow_head) * vec3(0.5, 0.5, 0.4);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
