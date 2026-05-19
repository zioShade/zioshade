#version 430
layout(location = 0) out vec4 FragColor;

// Test: integer arithmetic in render (SMod exercise)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int x = int(uv.x * 8.0);
    int y = int(uv.y * 8.0);
    float checker = float((x + y) % 2);
    vec3 col = mix(vec3(0.2, 0.3, 0.4), vec3(0.8, 0.7, 0.6), checker);
    FragColor = vec4(col, 1.0);
}
