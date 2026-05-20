#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    // Constant array initialized with explicit values
    const vec3 palette[4] = vec3[4](
        vec3(1.0, 0.0, 0.0),
        vec3(0.0, 1.0, 0.0),
        vec3(0.0, 0.0, 1.0),
        vec3(1.0, 1.0, 0.0)
    );
    int idx = int(gl_FragCoord.x) / 64;
    idx = clamp(idx, 0, 3);
    vec3 col = palette[idx];
    fragColor = vec4(col, 1.0);
}
