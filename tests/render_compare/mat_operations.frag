
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    mat2 m = mat2(0.707, -0.707, 0.707, 0.707);
    vec2 rotated = m * (uv - 0.5) + 0.5;
    float d = length(rotated - 0.5);
    vec3 col = vec3(smoothstep(0.3, 0.31, d) - smoothstep(0.35, 0.36, d));
    FragColor = vec4(col, 1.0);
}
