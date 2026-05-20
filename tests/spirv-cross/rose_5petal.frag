#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Rose curves with different petal counts
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float n = 5.0;
    float rose_r = 0.5 * cos(n * a);
    float d = r - abs(rose_r);
    float fill = smoothstep(0.02, 0.0, d) * step(0.0, rose_r);
    float edge = smoothstep(0.015, 0.005, abs(d)) * step(0.0, rose_r);
    vec3 col = vec3(0.02);
    col += vec3(0.7, 0.2, 0.5) * fill * 0.4;
    col += vec3(1.0, 0.5, 0.7) * edge;
    fragColor = vec4(col, 1.0);
}
