#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test multiple struct types and arrays of structs
struct Ray {
    vec2 origin;
    vec2 dir;
};

struct Hit {
    float t;
    int id;
};

Hit intersect(Ray r, vec2 center, float radius) {
    vec2 oc = r.origin - center;
    float a = dot(r.dir, r.dir);
    float b = 2.0 * dot(oc, r.dir);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - 4.0 * a * c;
    
    Hit h;
    h.t = -1.0;
    h.id = -1;
    
    if (disc > 0.0) {
        h.t = (-b - sqrt(disc)) / (2.0 * a);
        h.id = 0;
    }
    return h;
}

void main() {
    Ray r;
    r.origin = uv;
    r.dir = normalize(vec2(0.5) - uv);
    
    Hit h1 = intersect(r, vec2(0.3, 0.5), 0.15);
    Hit h2 = intersect(r, vec2(0.7, 0.5), 0.15);
    
    float col = 0.0;
    if (h1.t > 0.0) col = 0.8;
    if (h2.t > 0.0) col = 0.4;
    
    vec3 color = vec3(col, col * 0.5, col * 0.3);
    fragColor = vec4(color + vec3(0.05), 1.0);
}
