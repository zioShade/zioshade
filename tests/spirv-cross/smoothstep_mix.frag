#version 450

// Test: smoothstep and mix combined
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    vec3 a = vec3(0.2, 0.1, 0.4);
    vec3 b = vec3(0.9, 0.8, 0.3);
    float t = smoothstep(0.2, 0.8, uv.x);
    vec3 col = mix(a, b, t) * smoothstep(0.1, 0.9, uv.y);

    gl_FragColor = vec4(col, 1.0);
}
