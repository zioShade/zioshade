#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Zen garden (raked sand + rocks)
    float sand = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float freq = 3.0 + fi * 0.5;
        sand += sin(uv.x * freq + fi * 1.7) * 0.15;
    }
    sand = sand * 0.5 + 0.5;
    vec3 col = vec3(0.8, 0.75, 0.6) * sand;
    // Rocks
    float rock1 = smoothstep(0.5, 0.3, length(uv - vec2(3.0, 3.0)));
    float rock2 = smoothstep(0.3, 0.15, length(uv - vec2(7.0, 4.0)));
    col = mix(col, vec3(0.4, 0.38, 0.35), rock1);
    col = mix(col, vec3(0.35, 0.33, 0.3), rock2);
    fragColor = vec4(col, 1.0);
}
