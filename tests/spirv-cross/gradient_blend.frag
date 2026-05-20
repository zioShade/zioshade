#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.02;
    float t = 0.5;
    // Top-down blend of two noise-like patterns
    float n1 = sin(uv.x * 3.0) * cos(uv.y * 4.0) * 0.5 + 0.5;
    float n2 = cos(uv.x * 5.0 + 1.0) * sin(uv.y * 3.0 + 2.0) * 0.5 + 0.5;
    float combined = mix(n1, n2, t);
    vec3 warm = vec3(0.9, 0.6, 0.2);
    vec3 cool = vec3(0.2, 0.4, 0.8);
    vec3 col = mix(cool, warm, combined);
    fragColor = vec4(col, 1.0);
}
