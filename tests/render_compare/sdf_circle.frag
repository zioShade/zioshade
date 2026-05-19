#version 430
layout(location = 0) out vec4 FragColor;

// Test: SDF circle with soft edge
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = length(uv - 0.5) - 0.3;
    float edge = smoothstep(-0.02, 0.02, d);
    vec3 inside = vec3(0.8, 0.4, 0.2);
    vec3 outside = vec3(0.1, 0.2, 0.3);
    vec3 col = mix(inside, outside, edge);
    FragColor = vec4(col, 1.0);
}
