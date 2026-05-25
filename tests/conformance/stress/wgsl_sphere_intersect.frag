// Tests: function with multiple struct parameters
#version 450
layout(location = 0) out vec4 fragColor;

struct Sphere { vec3 center; float radius; };
struct Ray { vec3 origin; vec3 dir; };

float intersect(Sphere s, Ray r) {
    vec3 oc = r.origin - s.center;
    float a = dot(r.dir, r.dir);
    float b = dot(oc, r.dir);
    float c = dot(oc, oc) - s.radius * s.radius;
    float disc = b * b - a * c;
    if (disc < 0.0) return -1.0;
    return (-b - sqrt(disc)) / a;
}

void main() {
    Sphere s;
    s.center = vec3(0.0);
    s.radius = 1.0;
    Ray r;
    r.origin = vec3(0.0, 0.0, 3.0);
    r.dir = normalize(vec3(0.1, 0.1, -1.0));
    float t = intersect(s, r);
    vec3 color = t > 0.0 ? vec3(1.0) : vec3(0.2, 0.3, 0.5);
    fragColor = vec4(color, 1.0);
}
