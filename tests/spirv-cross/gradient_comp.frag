#version 450

// Test: gradient via smoothstep composition
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = smoothstep(0.0, 0.3, uv.x);
    float b = smoothstep(0.3, 0.7, uv.x);
    float c = smoothstep(0.7, 1.0, uv.x);

    vec3 col = vec3(a * 0.3, b * 0.7, c) * smoothstep(0.0, 1.0, uv.y);
    gl_FragColor = vec4(col, 1.0);
}
