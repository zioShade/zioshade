#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Starfield depth effect
    vec3 col = vec3(0.0);
    for (int layer = 0; layer < 3; layer++) {
        float fi = float(layer);
        float speed = 1.0 + fi * 0.5;
        float brightness = 0.3 + fi * 0.2;
        float scale = 5.0 + fi * 3.0;
        vec2 star_uv = uv * scale;
        vec2 star_id = floor(star_uv);
        vec2 star_f = fract(star_uv) - 0.5;
        float h = fract(sin(dot(star_id, vec2(127.1, 311.7))) * 43758.5);
        float size = h * 0.15;
        float star = smoothstep(size + 0.01, size, length(star_f));
        col += vec3(brightness) * star * step(0.85, h);
    }
    fragColor = vec4(col, 1.0);
}
