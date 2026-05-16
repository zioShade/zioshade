#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // UV tiling and wrapping with fract
    vec2 tiled = fract(uv * 4.0);
    float d = length(tiled - 0.5);
    float circle = 1.0 - smoothstep(0.3, 0.35, d);

    // Alternate tiling
    vec2 tiled2 = fract(uv * 3.0 + 0.25);
    float d2 = length(tiled2 - 0.5);
    float diamond = abs(tiled2.x - 0.5) + abs(tiled2.y - 0.5);
    float diamondShape = 1.0 - smoothstep(0.3, 0.35, diamond);

    fragColor = vec4(circle, diamondShape, circle * diamondShape, 1.0);
}
