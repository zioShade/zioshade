#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test nested function calls
    float scale(float x, float s) {
        return x * s;
    }
    float add_scaled(float a, float b, float s) {
        return a + scale(b, s);
    }
    float r = add_scaled(uv.x, uv.y, 2.0);
    float g = add_scaled(uv.y, uv.x, 3.0);
    fragColor = vec4(r, g, 0.5, 1.0);
}
