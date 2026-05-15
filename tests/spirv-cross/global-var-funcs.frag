#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test global variable and multiple functions
    float scale = 2.0;
    float transform(float x) {
        return x * scale + 0.5;
    }
    vec2 transform2(vec2 v) {
        return vec2(transform(v.x), transform(v.y));
    }
    vec2 result = transform2(uv);
    fragColor = vec4(result, 0.0, 1.0);
}
