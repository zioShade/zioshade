#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // vec3(scalar, vec2, scalar) — previously produced 4 components for vec3
    vec3 a = vec3(uv, 0.0);
    vec3 b = vec3(0.0, uv, 0.0);
    vec3 c = cross(a, b);
    vec3 col = c * 2.0 + 0.5;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
