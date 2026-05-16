#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Rotation matrix applied to UV coordinates
    float angle = uv.x * 3.14159;
    float c = cos(angle);
    float s = sin(angle);
    vec2 rotated = vec2(
        c * uv.x - s * uv.y,
        s * uv.x + c * uv.y
    );

    // Checkerboard on rotated coords
    vec2 grid = floor(rotated * 5.0);
    float checker = mod(grid.x + grid.y, 2.0);

    fragColor = vec4(vec3(checker), 1.0);
}
