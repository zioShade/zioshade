#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Circuits / PCB with vias and traces
    vec3 col = vec3(0.05, 0.2, 0.05);
    // Grid of potential traces
    float trace_h = 0.0;
    float trace_v = 0.0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float y = 1.0 + fi * 1.3;
        float x = 0.5 + fi * 1.5;
        trace_h += smoothstep(0.04, 0.02, abs(uv.y - y)) * step(2.0, uv.x) * step(uv.x, 12.0) * step(0.5, fract(sin(fi * 127.1) * 43758.5));
        trace_v += smoothstep(0.04, 0.02, abs(uv.x - x)) * step(1.0, uv.y) * step(uv.y, 10.0) * step(0.5, fract(sin(fi * 311.7) * 43758.5));
    }
    float traces = min(trace_h + trace_v, 1.0);
    col = mix(col, vec3(0.7, 0.55, 0.15), traces);
    // Vias (circles at intersections)
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        vec2 via_pos = vec2(fract(sin(fi * 127.1) * 43758.5) * 10.0 + 1.0, fract(sin(fi * 311.7) * 43758.5) * 8.0 + 1.0);
        float via_d = length(uv - via_pos);
        float via = smoothstep(0.12, 0.1, via_d) * (1.0 - smoothstep(0.06, 0.04, via_d));
        col = mix(col, vec3(0.15), via);
        col = mix(col, vec3(0.7, 0.7, 0.65), smoothstep(0.06, 0.04, via_d));
    }
    fragColor = vec4(col, 1.0);
}
