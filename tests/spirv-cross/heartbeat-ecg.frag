#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test heartbeat ECG/monitor pattern
void main() {
    vec3 col = vec3(0.0, 0.05, 0.0);
    
    // ECG trace: repeating heartbeat waveform
    float t = fract(uv.x * 2.0); // two cycles
    float y_center = 0.5;
    
    // Heartbeat shape (PQRST wave)
    float wave = 0.0;
    // P wave (small bump)
    wave += smoothstep(0.08, 0.12, t) * smoothstep(0.18, 0.14, t) * 0.03;
    // Q dip
    wave -= smoothstep(0.22, 0.24, t) * smoothstep(0.28, 0.26, t) * 0.04;
    // R spike (tall peak)
    wave += smoothstep(0.26, 0.28, t) * smoothstep(0.34, 0.30, t) * 0.2;
    // S dip
    wave -= smoothstep(0.30, 0.32, t) * smoothstep(0.36, 0.34, t) * 0.06;
    // T wave (rounded bump)
    wave += smoothstep(0.40, 0.45, t) * smoothstep(0.55, 0.50, t) * 0.04;
    
    float ecg_y = y_center + wave;
    float trace = smoothstep(0.008, 0.002, abs(uv.y - ecg_y));
    
    // Green phosphor color
    col += trace * vec3(0.1, 0.9, 0.1);
    
    // Grid lines (monitor background)
    float grid_major = smoothstep(0.003, 0.001, abs(fract(uv.x * 4.0) - 0.5)) +
                       smoothstep(0.003, 0.001, abs(fract(uv.y * 4.0) - 0.5));
    float grid_minor = smoothstep(0.002, 0.001, abs(fract(uv.x * 20.0) - 0.5)) +
                       smoothstep(0.002, 0.001, abs(fract(uv.y * 20.0) - 0.5));
    col += grid_major * vec3(0.0, 0.12, 0.0);
    col += grid_minor * vec3(0.0, 0.06, 0.0);
    
    // Glow around trace
    float glow = exp(-abs(uv.y - ecg_y) * 50.0) * 0.05;
    col += glow * vec3(0.0, 0.5, 0.0);
    
    // Slight scanline effect
    float scanline = 1.0 - smoothstep(0.0, 0.02, abs(fract(uv.y * 100.0) - 0.5)) * 0.05;
    col *= scanline;
    
    // Heart rate text area (simplified: just a bright region)
    float hr_box = step(0.7, uv.x) * step(uv.x, 0.95) * step(0.85, uv.y) * step(uv.y, 0.95);
    col += hr_box * vec3(0.0, 0.08, 0.0);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
