#version 430
layout(location = 0) out vec4 FragColor;

// Test: bool conversion chain
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    bool a = uv.x > 0.3;
    bool b = uv.y > 0.6;
    float f = float(a && b);
    float g = float(a || b);
    float h = float(!a);
    FragColor = vec4(f, g, h, 1.0);
}
