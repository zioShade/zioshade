#version 310 es
precision highp float;
out vec4 fragColor;

// Test: matrix column assignment
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    mat3 m = mat3(1.0);
    m[0] = vec3(sin(uv.x * 3.0), 0.0, 0.0);
    m[1] = vec3(0.0, cos(uv.y * 3.0), 0.0);
    m[2] = vec3(0.0, 0.0, 1.0);
    vec3 p = vec3(uv, 1.0);
    vec3 result = m * p;
    vec3 col = abs(result);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
