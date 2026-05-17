#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Voronoi-like pattern using distance comparison
void main() {
    vec2 p = uv * 5.0;
    vec2 ip = floor(p);
    vec2 fp = fract(p);
    
    float min_d = 1.0;
    float second_d = 1.0;
    
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 point = vec2(
                fract(sin(dot(ip + neighbor, vec2(127.1, 311.7))) * 43758.5453),
                fract(sin(dot(ip + neighbor, vec2(269.5, 183.3))) * 43758.5453)
            );
            float d = length(neighbor + point - fp);
            if (d < min_d) {
                second_d = min_d;
                min_d = d;
            } else if (d < second_d) {
                second_d = d;
            }
        }
    }
    
    float edge = second_d - min_d;
    vec3 col = vec3(min_d, edge, smoothstep(0.0, 0.05, edge));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
