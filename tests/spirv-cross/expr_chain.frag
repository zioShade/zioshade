#version 310 es
precision highp float;
out vec4 fragColor;

// Test: complex expression chains without temporaries
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    // Chain of operations in single expression
    vec3 col = clamp(
        vec3(
            sin(r * 10.0 + 0.0) * cos(uv.x * 5.0) * 0.5 + 0.5,
            sin(r * 10.0 + 2.09) * cos(uv.y * 5.0) * 0.5 + 0.5,
            sin(r * 10.0 + 4.18) * sin(r * 3.0) * 0.5 + 0.5
        ) * smoothstep(1.0, 0.3, r),
        vec3(0.0),
        vec3(1.0)
    );
    fragColor = vec4(col, 1.0);
}
