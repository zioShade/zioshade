#version 430
layout(location = 0) out vec4 FragColor;

// Test: procedural stripe pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float angle = 0.7854;
    vec2 dir = vec2(cos(angle), sin(angle));
    float proj = dot(uv, dir);
    float stripe = step(0.5, fract(proj * 8.0));
    vec3 col = mix(vec3(0.2, 0.3, 0.5), vec3(0.8, 0.7, 0.6), stripe);
    FragColor = vec4(col, 1.0);
}
