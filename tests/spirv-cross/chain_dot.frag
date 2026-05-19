#version 450

// Test: chained dot products and vector math
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 a = vec3(uv, 0.0);
    vec3 b = vec3(0.0, uv);
    vec3 c = cross(a, b);
    float d1 = dot(a, b);
    float d2 = dot(b, c);
    float d3 = dot(a, c);
    vec3 n = normalize(a + b + c);

    gl_FragColor = vec4(n * 0.5 + 0.5, (d1 + d2 + d3) * 0.1 + 0.5);
}
