// Test: Voronoi diagram
#version 450

layout(location = 0) out vec4 fragColor;

vec2 hash2(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    uv *= 5.0;
    
    vec2 ip = floor(uv);
    vec2 fp = fract(uv);
    
    float minDist = 10.0;
    float secondDist = 10.0;
    vec2 minPoint = vec2(0.0);
    
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 point = hash2(ip + neighbor);
            vec2 diff = neighbor + point - fp;
            float d = length(diff);
            
            if (d < minDist) {
                secondDist = minDist;
                minDist = d;
                minPoint = point;
            } else if (d < secondDist) {
                secondDist = d;
            }
        }
    }
    
    float edge = secondDist - minDist;
    vec3 color = vec3(minDist * 0.5);
    color += vec3(0.3) * (1.0 - smoothstep(0.0, 0.05, edge));
    
    fragColor = vec4(color, 1.0);
}
