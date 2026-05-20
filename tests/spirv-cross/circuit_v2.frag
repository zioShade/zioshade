#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Circuit board traces v2 with chips
    vec2 cell = floor(uv);
    vec2 f = fract(uv);
    float h = fract(sin(dot(cell, vec2(127.1, 311.7))) * 43758.5);
    // PCB base
    vec3 col = vec3(0.05, 0.25, 0.05);
    // Traces
    float trace = 0.0;
    if (h > 0.3 && h < 0.5) {
        trace = smoothstep(0.04, 0.02, abs(f.y - 0.5));
    } else if (h > 0.5 && h < 0.7) {
        trace = smoothstep(0.04, 0.02, abs(f.x - 0.5));
    }
    col = mix(col, vec3(0.7, 0.55, 0.15), trace);
    // IC chip
    float is_chip = step(0.9, h);
    float chip = smoothstep(0.15, 0.12, max(abs(f.x - 0.5), abs(f.y - 0.5))) * is_chip;
    col = mix(col, vec3(0.15, 0.15, 0.15), chip);
    // Pins
    float pin = smoothstep(0.05, 0.03, abs(f.x - 0.5)) * smoothstep(0.4, 0.35, f.y) * is_chip;
    col = mix(col, vec3(0.8, 0.8, 0.7), pin);
    fragColor = vec4(col, 1.0);
}
