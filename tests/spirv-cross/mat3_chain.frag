#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // mat3 transformation chain: scale -> rotate -> translate
    float angle = uv.x * 1.0;
    float c = cos(angle);
    float s = sin(angle);
    mat3 rotate = mat3(
        c, s, 0.0,
        -s, c, 0.0,
        0.0, 0.0, 1.0
    );
    vec3 pos = vec3(uv, 1.0);
    vec3 transformed = rotate * pos;
    float r = length(transformed.xy);
    float pattern = sin(r * 20.0) * 0.5 + 0.5;
    vec3 col = vec3(pattern) * vec3(0.3, 0.5, 0.8) * smoothstep(1.0, 0.3, r);
    fragColor = vec4(col, 1.0);
}
