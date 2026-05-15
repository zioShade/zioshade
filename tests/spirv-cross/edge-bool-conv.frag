#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;
void main() {
    bool b = uv.x > 0.5;
    int a = int(b);
    float c = float(a);
    fragColor = vec4(c, 0.0, uv.y, 1.0);
}
