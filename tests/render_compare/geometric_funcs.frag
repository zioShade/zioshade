#version 430
layout(location = 0) out vec4 FragColor;

// Test length, distance, dot, normalize, reflect
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    vec2 a = uv * 2.0 - 1.0;
    vec2 b = vec2(0.3, 0.7);
    float r = length(a);
    float g = distance(a, b);
    float d = dot(a, b);
    float bl = clamp(d * 0.5 + 0.5, 0.0, 1.0);
    vec2 ref = reflect(a, normalize(b));
    float al = clamp(ref.x * 0.5 + 0.5, 0.0, 1.0);
    FragColor = vec4(r, g, bl, al);
}
