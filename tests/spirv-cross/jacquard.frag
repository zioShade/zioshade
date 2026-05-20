#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Jacquard loom / woven textile pattern
    float warp_freq = 20.0;
    float weft_freq = 18.0;
    float warp = sin(uv.x * warp_freq) * 0.5 + 0.5;
    float weft = sin(uv.y * weft_freq + sin(uv.x * 2.0) * 3.0) * 0.5 + 0.5;
    // Complex pattern from combined signals
    float pattern = warp * weft;
    // Damask-style dual tone
    vec3 bg = vec3(0.6, 0.1, 0.1);
    vec3 fg = vec3(0.85, 0.2, 0.15);
    vec3 col = mix(bg, fg, step(0.3, pattern));
    // Thread texture
    float thread = smoothstep(0.05, 0.02, abs(fract(uv.x * warp_freq / 6.28) - 0.5));
    col *= 0.9 + 0.1 * thread;
    fragColor = vec4(col, 1.0);
}
