#version 450

// Test: vec4/vec3/vec2 implicit conversions and constructors
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    // Scalar to vector promotion
    vec4 a = vec4(0.5);
    vec3 b = vec3(1.0);
    vec2 c = vec2(0.0);

    // Replicate scalar
    vec4 d = vec4(uv.x);
    vec3 e = vec3(uv.y);

    gl_FragColor = vec4(d.x, e.x, a.x + b.x + c.x, 1.0);
}
