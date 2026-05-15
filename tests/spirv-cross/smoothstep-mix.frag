#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test smoothstep, clamp, mix chains
    float a = smoothstep(0.0, 1.0, uv.x);
    float b = smoothstep(0.2, 0.8, uv.y);
    float c = clamp(a * 3.0 - 1.0, 0.0, 1.0);
    float d = mix(a, b, c);

    // Test vec3 from mixed scalars and vectors
    vec3 color = vec3(d, a, b);

    // Test normalize and length
    vec2 dir = uv - 0.5;
    float len = length(dir);
    vec2 norm = normalize(dir);

    fragColor = vec4(color + vec3(norm, len * 0.5), 1.0);
}
