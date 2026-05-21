#version 310 es
precision highp float;
out vec4 fragColor;

// Test: mat4 construction and column access
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    mat4 m = mat4(
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        uv.x, uv.y, 0.0, 1.0
    );
    vec4 col0 = m[0];
    vec4 col3 = m[3];
    vec3 col = col0.rgb * 0.3 + col3.rgb * 0.5;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
