#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test seismograph / waveform recording
void main() {
    vec3 col = vec3(0.95, 0.93, 0.88); // paper
    
    float y_center = 0.5;
    float amplitude = 0.15;
    
    // Multiple seismic traces
    for (int trace = 0; trace < 3; trace++) {
        float ft = float(trace);
        float y_offset = y_center + (ft - 1.0) * 0.25;
        
        // Composite waveform
        float x = uv.x * 20.0;
        float wave = 0.0;
        wave += sin(x * 3.0 + ft * 2.0) * 0.5;
        wave += sin(x * 7.0 + ft * 1.3) * 0.3;
        
        // P-wave arrival spike
        float spike_pos = 0.4 + ft * 0.1;
        float spike = exp(-pow((uv.x - spike_pos) * 20.0, 2.0)) * 2.0;
        wave += spike * sin(x * 15.0) * 0.4;
        
        // Attenuation after spike
        float atten = 1.0 - smoothstep(spike_pos, spike_pos + 0.4, uv.x) * 0.5;
        wave *= atten;
        
        float y = uv.y - y_offset;
        float line = smoothstep(0.008, 0.002, abs(y - wave * amplitude));
        
        // Trace color
        vec3 trace_col;
        if (trace == 0) trace_col = vec3(0.1, 0.1, 0.7);
        else if (trace == 1) trace_col = vec3(0.1, 0.7, 0.1);
        else trace_col = vec3(0.7, 0.1, 0.1);
        
        col = mix(col, trace_col, line);
        
        // Baseline
        float baseline = smoothstep(0.003, 0.001, abs(y)) * 0.15;
        col = mix(col, trace_col * 0.3, baseline);
    }
    
    // Grid lines
    float grid_v = smoothstep(0.003, 0.001, abs(fract(uv.x * 10.0) - 0.5));
    float grid_h = smoothstep(0.003, 0.001, abs(fract(uv.y * 4.0) - 0.5));
    col = mix(col, vec3(0.8, 0.8, 0.85), max(grid_v, grid_h) * 0.3);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
