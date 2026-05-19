#version 450

// Test: mix with bool condition (OpSelect)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 0.0, 1.0);
    bool cond = uv.x > 0.5;
    vec3 c = cond ? a : b;

    float d = mix(0.2, 0.8, uv.y);
    vec3 e = mix(vec3(0.1), vec3(0.9), vec3(uv, 0.5));

    gl_FragColor = vec4(c * d, 1.0);
}
