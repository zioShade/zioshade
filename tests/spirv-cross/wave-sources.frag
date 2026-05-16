#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Wave interference from multiple point sources
    float sum = 0.0;
    vec2 sources[3];
    sources[0] = vec2(0.25, 0.3);
    sources[1] = vec2(0.75, 0.3);
    sources[2] = vec2(0.5, 0.8);

    for (int i = 0; i < 3; i++) {
        float d = length(uv - sources[i]);
        sum += sin(d * 40.0) / (d * 5.0 + 1.0);
    }

    vec3 col = vec3(0.0);
    col += vec3(0.1, 0.3, 0.8) * smoothstep(0.0, 0.5, sum);
    col += vec3(0.8, 0.2, 0.1) * smoothstep(0.0, -0.5, sum);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
