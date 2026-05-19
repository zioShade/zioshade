#version 450
layout(location = 0) out vec4 FragColor;
struct Ray { vec3 origin; vec3 dir; };
struct Hit { float t; vec3 normal; bool valid; };
Hit intersect(Ray r) {
    float b = dot(r.origin, r.dir);
    float c = dot(r.origin, r.origin) - 1.0;
    float disc = b * b - c;
    Hit h;
    h.valid = disc > 0.0;
    h.t = -b - sqrt(max(disc, 0.0));
    vec3 p = r.origin + r.dir * h.t;
    h.normal = normalize(p);
    return h;
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    Ray r;
    r.origin = vec3(0.0, 0.0, -2.0);
    r.dir = normalize(vec3(uv, 1.0));
    Hit h = intersect(r);
    vec3 col = vec3(0.1);
    if (h.valid && h.t > 0.0) {
        float diff = max(dot(h.normal, normalize(vec3(1.0, 1.0, -1.0))), 0.0);
        col = vec3(0.8, 0.4, 0.2) * (diff * 0.7 + 0.3);
    }
    FragColor = vec4(col, 1.0);
}
