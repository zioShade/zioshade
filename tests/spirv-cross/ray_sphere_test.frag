#version 310 es
precision highp float;
out vec4 fragColor;

struct Ray { vec3 o, d; };

float hitSphere(Ray r, vec3 center, float radius) {
    vec3 oc = r.o - center;
    float a = dot(r.d, r.d);
    float b = 2.0 * dot(oc, r.d);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - 4.0 * a * c;
    if (disc < 0.0) return -1.0;
    return (-b - sqrt(disc)) / (2.0 * a);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Ray r;
    r.o = vec3(0.0, 0.0, 3.0);
    r.d = normalize(vec3(uv, -1.0));
    float t = hitSphere(r, vec3(0.0), 1.0);
    if (t > 0.0) {
        vec3 n = normalize(r.o + r.d * t);
        fragColor = vec4(n * 0.5 + 0.5, 1.0);
    } else {
        fragColor = vec4(0.1, 0.1, 0.2, 1.0);
    }
}
