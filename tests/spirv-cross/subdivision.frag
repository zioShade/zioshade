#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Recursive subdivision pattern
    vec2 p = uv;
    float scale = 1.0;
    float pattern = 0.0;

    for (int i = 0; i < 5; i++) {
        vec2 cell = fract(p * scale);
        vec2 id = floor(p * scale);

        float d = length(cell - 0.5);
        float ring = abs(d - 0.3);

        // Color based on cell ID
        float cell_hash = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5453);
        pattern += smoothstep(0.1, 0.0, ring) * cell_hash * 0.3;

        scale *= 2.0;
    }

    vec3 col = vec3(pattern, pattern * 0.8, pattern * 0.6);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
