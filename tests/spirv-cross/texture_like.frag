#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 grid = fract(uv * 8.0);
    float d = length(grid - 0.5);
    float ring = smoothstep(0.3, 0.28, d) - smoothstep(0.2, 0.18, d);
    vec3 col = vec3(ring, ring * 0.5, ring * 0.3);
    FragColor = vec4(col, 1.0);
}
