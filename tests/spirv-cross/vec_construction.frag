#version 450

// Test: vec3/vec4 construction from mixed components
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 a = uv;
    float b = 0.5;
    float c = 0.3;

    vec3 v1 = vec3(a, b);
    vec3 v2 = vec3(b, a);
    vec4 v3 = vec4(a, b, c);
    vec4 v4 = vec4(v1, c);
    vec4 v5 = vec4(b, v2);

    gl_FragColor = (v3 + v4 + v5) / 3.0;
}
