#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Ishihara color blindness test plate
    float r = length(uv - vec2(5.0, 5.0));
    // Dots with varying size and color
    vec3 col = vec3(0.8, 0.7, 0.3);
    for (int i = 0; i < 40; i++) {
        float fi = float(i);
        vec2 center = vec2(
            fract(sin(fi * 127.1) * 43758.5) * 10.0,
            fract(sin(fi * 311.7) * 43758.5) * 10.0
        );
        float d = length(uv - center);
        float size = 0.15 + fract(sin(fi * 74.3) * 43758.5) * 0.25;
        float dot = smoothstep(size, size - 0.05, d);
        // Number 8 shape
        float in_number = 0.0;
        float dr = length(uv - vec2(5.0, 5.5));
        if (dr < 2.0 && dr > 0.5) in_number = 1.0;
        dr = length(uv - vec2(5.0, 4.0));
        if (dr < 1.5 && dr > 0.4) in_number = 1.0;
        vec3 bg_dot = vec3(0.7, 0.6, 0.2) * (0.8 + fract(fi * 13.7) * 0.4);
        vec3 num_dot = vec3(0.4, 0.2, 0.1) * (0.8 + fract(fi * 93.1) * 0.4);
        col = mix(col, mix(bg_dot, num_dot, in_number), dot);
    }
    fragColor = vec4(col, 1.0);
}
