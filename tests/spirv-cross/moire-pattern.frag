#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Moire pattern from overlapping grids
    float scale1 = 40.0;
    float scale2 = 41.0;

    float g1 = sin(uv.x * scale1) * sin(uv.y * scale1);
    float g2 = sin(uv.x * scale2) * sin(uv.y * scale2);

    float moire = (g1 + g2) * 0.5;

    vec3 col = vec3(moire * 0.5 + 0.5);
    col *= vec3(0.9, 0.7, 1.0);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
