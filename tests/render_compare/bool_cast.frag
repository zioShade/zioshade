#version 430
layout(location = 0) out vec4 FragColor;

// Test bool/int/float conversions
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    bool b = uv.x > 0.5;
    int i = int(b);
    float f = float(i);
    bool b2 = bool(uv.y);
    int i2 = int(uv.y * 3.0);
    float f2 = float(i2) / 3.0;
    FragColor = vec4(f, f2, float(b2), 1.0);
}
