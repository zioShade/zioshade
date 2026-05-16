#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Shadow ray marcher
    vec2 light_pos = vec2(0.5, 0.8);
    vec2 p = uv;

    // Simple sphere SDF
    float sphere = length(uv - vec2(0.5, 0.4)) - 0.15;

    // March from point to light
    vec2 dir = normalize(light_pos - p);
    float dist_to_light = length(light_pos - p);
    float shadow = 1.0;

    for (int i = 0; i < 32; i++) {
        vec2 sample_pos = p + dir * dist_to_light * float(i) / 32.0;
        float d = length(sample_pos - vec2(0.5, 0.4)) - 0.15;
        if (d < 0.001) {
            shadow = 0.0;
            break;
        }
    }

    // Light attenuation
    float light_dist = length(p - light_pos);
    float attenuation = 1.0 / (1.0 + light_dist * 5.0);

    vec3 col = vec3(0.8, 0.9, 1.0) * shadow * attenuation;
    col += smoothstep(0.01, 0.0, sphere) * vec3(0.2, 0.3, 0.5);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
