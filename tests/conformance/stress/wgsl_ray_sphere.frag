#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

struct Ray {
    vec3 origin;
    vec3 dir;
};

vec3 pointAt(Ray r, float t) {
    return r.origin + r.dir * t;
}

float hitSphere(vec3 center, float radius, Ray r) {
    vec3 oc = r.origin - center;
    float a = dot(r.dir, r.dir);
    float b = 2.0 * dot(oc, r.dir);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - 4.0 * a * c;
    if (disc < 0.0) return -1.0;
    return (-b - sqrt(disc)) / (2.0 * a);
}

void main() {
    Ray r;
    r.origin = vec3(0.0, 0.0, 2.0);
    r.dir = normalize(vec3(uv * 2.0 - 1.0, -1.0));

    float t = hitSphere(vec3(0.0, 0.0, -1.0), 0.8, r);
    vec3 color = vec3(0.1, 0.1, 0.2);

    if (t > 0.0) {
        vec3 p = pointAt(r, t);
        vec3 normal = normalize(p - vec3(0.0, 0.0, -1.0));
        color = vec3(normal.x + 1.0, normal.y + 1.0, normal.z + 1.0) * 0.5;
    }

    fragColor = vec4(color, 1.0);
}
