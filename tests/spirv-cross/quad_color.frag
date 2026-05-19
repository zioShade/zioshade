#version 450

// Test: face-dependent output using step
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float cx = step(0.5, uv.x);
    float cy = step(0.5, uv.y);

    vec3 a = vec3(1.0, 0.3, 0.1);
    vec3 b = vec3(0.1, 0.3, 1.0);
    vec3 c = vec3(0.1, 0.8, 0.3);
    vec3 d = vec3(0.9, 0.9, 0.1);

    vec3 col = mix(mix(a, b, cx), mix(c, d, cx), cy);
    gl_FragColor = vec4(col, 1.0);
}
