#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.02;
    // Quasicrystal pattern
    float scale = 10.0;
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        float angle = float(i) * 1.2566; // 2*pi/5
        vec2 dir = vec2(cos(angle), sin(angle));
        sum += cos(dot(uv, dir) * scale);
    }
    float pattern = sum / 5.0;
    vec3 col = vec3(pattern * 0.5 + 0.5);
    col = pow(col, vec3(0.8, 0.9, 1.0));
    fragColor = vec4(col, 1.0);
}
