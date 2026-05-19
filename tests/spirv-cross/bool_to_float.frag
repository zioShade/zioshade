#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    bool a = uv.x > 0.5;
    bool b = uv.y > 0.5;
    float fa = float(a);
    float fb = float(b);
    float fc = float(a && b);
    FragColor = vec4(fa, fb, fc, 1.0);
}
