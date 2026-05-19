#version 430
layout(location = 0) out vec4 FragColor;

// Test mod with scalar promotion
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    vec2 v = mod(uv * 5.0, 1.5);
    float s = mod(uv.x * 3.0, 0.7);
    FragColor = vec4(v, s, 1.0);
}
