#version 430
layout(location = 0) out vec4 FragColor;

// Test: integer SMod with checkerboard (exercises SMod naming fix)
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int x = int(uv.x * 10.0);
    int y = int(uv.y * 10.0);
    float checker = float((x % 3 + y % 3) % 2);
    vec3 col = mix(vec3(0.9, 0.85, 0.7), vec3(0.2, 0.15, 0.1), checker);
    FragColor = vec4(col, 1.0);
}
