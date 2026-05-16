#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Newton's method for sqrt
void main() {
    float s = uv.x * 4.0;  // find sqrt(s)
    float x = s;  // initial guess
    
    for (int i = 0; i < 8; i++) {
        x = 0.5 * (x + s / x);
    }
    
    float r = x / 2.0;
    float g = uv.y;
    float b = abs(r * r - s);  // should be ~0
    
    fragColor = vec4(r, g, clamp(b, 0.0, 1.0), 1.0);
}
