#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / 128.0;
    float d = length(uv - 0.5);
    float ring = smoothstep(0.25, 0.26, d) - smoothstep(0.3, 0.31, d);
    float ring2 = smoothstep(0.15, 0.16, d) - smoothstep(0.2, 0.21, d);
    FragColor = vec4(ring, ring2, ring + ring2, 1.0);
}
