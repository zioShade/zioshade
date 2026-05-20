#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Polar rose curve
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    float k = 7.0; // 7-petal rose
    float rose_r = 0.5 * cos(k * a);
    float d = abs(r - abs(rose_r));
    float petal = smoothstep(0.02, 0.01, d) * step(0.0, rose_r);
    // Fill petals
    float fill = smoothstep(0.02, 0.0, r - abs(rose_r)) * step(0.0, rose_r);
    vec3 col = vec3(0.05);
    col += vec3(0.8, 0.3, 0.5) * fill * 0.3;
    col += vec3(1.0, 0.5, 0.7) * petal;
    fragColor = vec4(col, 1.0);
}
