#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float d = length(uv - vec2(0.5));
    float ring1 = smoothstep(0.28, 0.3, d) - smoothstep(0.3, 0.32, d);
    float ring2 = smoothstep(0.18, 0.2, d) - smoothstep(0.2, 0.22, d);
    float ring3 = smoothstep(0.08, 0.1, d) - smoothstep(0.1, 0.12, d);
    vec3 col = vec3(ring1, ring2 * 0.5, ring3);
    FragColor = vec4(col, 1.0);
}
