#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Kaleidoscope with 6-fold symmetry
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    float segments = 6.0;
    float seg_a = 6.2832 / segments;
    a = mod(a, seg_a);
    a = abs(a - seg_a * 0.5);
    vec2 p = vec2(cos(a), sin(a)) * r;
    // Pattern inside
    float pattern = sin(p.x * 20.0) * cos(p.y * 20.0);
    pattern += sin(r * 15.0) * 0.5;
    pattern = pattern * 0.5 + 0.5;
    vec3 col = vec3(pattern, pattern * 0.7, pattern * 0.4);
    col *= smoothstep(1.0, 0.2, r);
    fragColor = vec4(col, 1.0);
}
