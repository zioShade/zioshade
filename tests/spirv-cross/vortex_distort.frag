#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Vortex distortion
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float twist = 3.0 / (r + 0.3);
    float twisted_a = a + twist;
    vec2 twisted_uv = vec2(cos(twisted_a), sin(twisted_a)) * r;
    // Sample pattern at twisted coordinates
    float pattern = sin(twisted_uv.x * 20.0) * sin(twisted_uv.y * 20.0);
    pattern = pattern * 0.5 + 0.5;
    vec3 col = mix(vec3(0.1, 0.3, 0.6), vec3(0.9, 0.7, 0.2), pattern);
    col *= smoothstep(1.2, 0.5, r);
    fragColor = vec4(col, 1.0);
}
