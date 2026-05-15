#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Ray-sphere intersection — exercises struct, functions, dot/normalize/sqrt, conditional return
struct Ray {
    vec3 origin;
    vec3 dir;
    float t;
};

Ray makeRay(vec2 p) {
    Ray r;
    r.origin = vec3(p, 0.0);
    r.dir = normalize(vec3(p * 2.0 - 1.0, -1.0));
    r.t = 1e10;
    return r;
}

float hitSphere(Ray r, vec3 center, float radius) {
    vec3 oc = r.origin - center;
    float b = dot(oc, r.dir);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0) return -1.0;
    return -b - sqrt(disc);
}

void main() {
    Ray r = makeRay(uv);
    float t = hitSphere(r, vec3(0.0), 0.5);
    if (t > 0.0) {
        vec3 p = r.origin + r.dir * t;
        fragColor = vec4(abs(p), 1.0);
    } else {
        fragColor = vec4(0.2, 0.3, 0.5, 1.0);
    }
}
