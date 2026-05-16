#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Voronoi-like cells
    vec2 p = uv * 5.0;
    vec2 ip = floor(p);
    vec2 fp = fract(p);

    float min_dist = 1.0;
    vec2 min_point = vec2(0.0);

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 point = vec2(
                fract(sin(dot(ip + neighbor, vec2(127.1, 311.7))) * 43758.5453),
                fract(sin(dot(ip + neighbor, vec2(269.5, 183.3))) * 43758.5453)
            );
            float dist = length(neighbor + point - fp);
            if (dist < min_dist) {
                min_dist = dist;
                min_point = point;
            }
        }
    }

    vec3 col = vec3(min_dist);
    col *= 0.5 + 0.5 * cos(min_point.x * 6.28 + vec3(0.0, 1.0, 2.0));

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
