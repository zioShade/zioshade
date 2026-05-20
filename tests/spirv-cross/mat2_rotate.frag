#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // 2D rotation via matrix
    float angle = uv.x * 3.14;
    float c = cos(angle);
    float s = sin(angle);
    mat2 rot = mat2(c, s, -s, c);
    vec2 rotated = rot * uv;
    float pattern = sin(rotated.x * 20.0) * sin(rotated.y * 20.0);
    pattern = pattern * 0.5 + 0.5;
    vec3 col = vec3(pattern) * vec3(0.3, 0.6, 0.9);
    col *= smoothstep(1.2, 0.3, length(uv));
    fragColor = vec4(col, 1.0);
}
