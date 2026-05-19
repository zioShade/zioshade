#version 430
layout(location = 0) out vec4 FragColor;

// Test: voronoi pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 4.0;
    vec2 ip = floor(uv);
    vec2 fp = fract(uv);

    float minDist = 1.0;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 point = vec2(
                fract(sin(dot(ip + neighbor, vec2(127.1, 311.7))) * 43758.5453),
                fract(sin(dot(ip + neighbor, vec2(269.5, 183.3))) * 43758.5453)
            );
            float d = length(neighbor + point - fp);
            minDist = min(minDist, d);
        }
    }

    vec3 col = vec3(minDist);
    FragColor = vec4(col, 1.0);
}
