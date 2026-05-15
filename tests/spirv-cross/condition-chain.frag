#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test condition chain (multiple if/else if)
    vec3 color;
    if (uv.x < 0.25) {
        color = vec3(1.0, 0.0, 0.0);
    } else if (uv.x < 0.5) {
        color = vec3(0.0, 1.0, 0.0);
    } else if (uv.x < 0.75) {
        color = vec3(0.0, 0.0, 1.0);
    } else {
        color = vec3(1.0, 1.0, 0.0);
    }
    fragColor = vec4(color, 1.0);
}
