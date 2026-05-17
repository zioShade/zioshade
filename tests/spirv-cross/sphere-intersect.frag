#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test struct passing to functions
struct Sphere {
    vec3 center;
    float radius;
    vec3 color;
};

float intersect(Sphere s, vec3 ro, vec3 rd) {
    vec3 oc = ro - s.center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - s.radius * s.radius;
    float h = b * b - c;
    if (h < 0.0) return -1.0;
    return -b - sqrt(h);
}

void main() {
    Sphere s;
    s.center = vec3(0.0, 0.0, 2.0);
    s.radius = 0.8;
    s.color = vec3(0.7, 0.3, 0.2);
    
    vec3 ro = vec3(uv * 2.0 - 1.0, 0.0);
    vec3 rd = vec3(0.0, 0.0, 1.0);
    
    float t = intersect(s, ro, rd);
    
    vec3 col = vec3(0.05);
    if (t > 0.0) {
        col = s.color * (1.0 - t * 0.3);
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
