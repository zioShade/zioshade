#version 450

// Test: 2D rotation matrix applied to point
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv - 0.5;

    float angle = uv.y * 6.28;
    float ca = cos(angle);
    float sa = sin(angle);

    vec2 rotated = vec2(
        p.x * ca - p.y * sa,
        p.x * sa + p.y * ca
    );

    vec3 col = vec3(rotated * 0.5 + 0.5, 0.5);
    gl_FragColor = vec4(col, 1.0);
}
