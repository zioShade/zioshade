#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Voronoi-like pattern
    vec2 p = uv * 5.0;
    vec2 ip = floor(p);
    float min_dist = 1.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 point = fract(vec2(
                sin(dot(ip + neighbor, vec2(127.1, 311.7))) * 43758.5453,
                sin(dot(ip + neighbor, vec2(269.5, 183.3))) * 43758.5453
            ));
            float d = length(neighbor + point - fract(p));
            if (d < min_dist) min_dist = d;
        }
    }
    fragColor = vec4(min_dist, min_dist * 0.8, min_dist * 0.5, 1.0);
}
