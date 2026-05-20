#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Circuit board pattern
    vec2 grid = fract(uv) - 0.5;
    vec2 id = floor(uv);
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5453);
    // Traces (horizontal/vertical lines)
    float trace_h = smoothstep(0.04, 0.02, abs(grid.y)) * step(0.5, h);
    float trace_v = smoothstep(0.04, 0.02, abs(grid.x)) * step(h, 0.3);
    float trace = max(trace_h, trace_v);
    // Pads (circles at intersections)
    float pad = smoothstep(0.08, 0.05, length(grid)) * step(0.7, h);
    // Via holes
    float via = smoothstep(0.04, 0.02, length(grid)) * step(0.8, h);
    vec3 board = vec3(0.1, 0.3, 0.1);
    vec3 copper = vec3(0.7, 0.5, 0.2);
    vec3 col = board;
    col = mix(col, copper, trace);
    col = mix(col, vec3(0.8, 0.6, 0.3), pad);
    col = mix(col, vec3(0.2), via);
    fragColor = vec4(col, 1.0);
}
