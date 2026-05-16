#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Star field
    vec2 p = uv * 50.0;
    vec2 ip = floor(p);
    vec2 fp = fract(p);

    float star = 0.0;
    float h = fract(sin(dot(ip, vec2(127.1, 311.7))) * 43758.5453);

    if (h > 0.95) {
        // This cell has a star
        vec2 star_pos = vec2(
            fract(sin(dot(ip, vec2(269.5, 183.3))) * 43758.5453),
            fract(sin(dot(ip, vec2(420.2, 631.2))) * 43758.5453)
        );
        float d = length(fp - star_pos);
        star = smoothstep(0.15, 0.0, d);
        star *= h;  // brightness variation
    }

    vec3 col = vec3(0.02, 0.02, 0.05);  // dark sky
    col += vec3(0.9, 0.85, 1.0) * star;

    fragColor = vec4(col, 1.0);
}
