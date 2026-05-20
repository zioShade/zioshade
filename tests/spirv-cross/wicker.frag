#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Woven reed / wicker pattern
    float h_freq = 8.0;
    float v_freq = 10.0;
    float hx = sin(uv.x * h_freq * 6.28) * 0.5 + 0.5;
    float vy = sin(uv.y * v_freq * 6.28) * 0.5 + 0.5;
    // Checkerboard over/under
    float checker = mod(floor(uv.x * h_freq) + floor(uv.y * v_freq), 2.0);
    float h_visible = checker > 0.5 ? hx : hx * 0.5;
    float v_visible = checker > 0.5 ? vy * 0.5 : vy;
    vec3 reed_light = vec3(0.8, 0.7, 0.4);
    vec3 reed_dark = vec3(0.6, 0.5, 0.3);
    vec3 col = mix(reed_dark, reed_light, max(h_visible, v_visible));
    fragColor = vec4(col, 1.0);
}
