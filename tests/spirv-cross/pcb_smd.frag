#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Printed circuit board with traces and components
    vec2 cell = floor(uv * 2.0);
    vec2 f = fract(uv * 2.0);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // PCB base (green soldermask)
    vec3 col = vec3(0.05, 0.25, 0.05);
    // Copper traces
    float trace = 0.0;
    if (h > 0.3 && h < 0.6) {
        trace = smoothstep(0.06, 0.03, abs(f.y - 0.5));
    } else if (h >= 0.6 && h < 0.85) {
        trace = smoothstep(0.06, 0.03, abs(f.x - 0.5));
    }
    col = mix(col, vec3(0.7, 0.55, 0.15), trace);
    // SMD components
    float comp = smoothstep(0.25, 0.2, max(abs(f.x - 0.5), abs(f.y - 0.5))) * step(0.85, h);
    col = mix(col, vec3(0.15), comp);
    fragColor = vec4(col, 1.0);
}
