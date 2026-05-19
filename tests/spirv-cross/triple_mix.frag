#version 450

// Test: triple mix composition
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 1.0, 0.0);
    vec3 c = vec3(0.0, 0.0, 1.0);

    vec3 ab = mix(a, b, uv.x);
    vec3 bc = mix(b, c, uv.y);
    vec3 result = mix(ab, bc, 0.5);

    gl_FragColor = vec4(result, 1.0);
}
