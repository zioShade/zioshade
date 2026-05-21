#version 310 es
precision highp float;
out vec4 fragColor;

struct Ray2 { vec3 origin; vec3 dir; };
struct Hit2 { float t; vec3 normal; int id; };

Hit2 intersectSphere(Ray2 r, vec3 center, float radius) {
    vec3 oc = r.origin - center;
    float b = dot(oc, r.dir);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - c;
    Hit2 h;
    h.t = -1.0;
    h.id = -1;
    h.normal = vec3(0.0);
    if (disc > 0.0) {
        h.t = -b - sqrt(disc);
        h.normal = normalize(oc + h.t * r.dir);
        h.id = 1;
    }
    return h;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Ray2 r = Ray2(vec3(0.0, 0.0, -2.0), normalize(vec3(uv, 1.0)));
    Hit2 h1 = intersectSphere(r, vec3(-0.3, 0.0, 0.0), 0.4);
    Hit2 h2 = intersectSphere(r, vec3(0.4, 0.0, 0.0), 0.3);
    vec3 col = vec3(0.05);
    if (h1.t > 0.0) {
        col = vec3(0.8, 0.2, 0.1) * max(dot(h1.normal, normalize(vec3(1.0, 1.0, -1.0))), 0.0);
    }
    if (h2.t > 0.0 && (h1.t < 0.0 || h2.t < h1.t)) {
        col = vec3(0.1, 0.2, 0.8) * max(dot(h2.normal, normalize(vec3(1.0, 1.0, -1.0))), 0.0);
    }
    fragColor = vec4(col + vec3(0.05), 1.0);
}
