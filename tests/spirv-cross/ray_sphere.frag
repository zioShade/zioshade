#version 450

// Test: Access chain with struct members
struct Sphere {
    vec3 center;
    float radius;
    vec3 color;
};

float intersectSphere(vec3 ro, vec3 rd, Sphere s) {
    vec3 oc = ro - s.center;
    float b = dot(oc, rd);
    float c = dot(oc, oc) - s.radius * s.radius;
    float h = b * b - c;
    if (h < 0.0) return -1.0;
    return -b - sqrt(h);
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 ro = vec3(0.0, 0.0, 3.0);
    vec3 rd = normalize(vec3(uv * 2.0 - 1.0, -1.0));

    Sphere s;
    s.center = vec3(0.0);
    s.radius = 1.0;
    s.color = vec3(0.8, 0.3, 0.1);

    float t = intersectSphere(ro, rd, s);
    vec3 col = t > 0.0 ? s.color * (t / 4.0) : vec3(0.1, 0.1, 0.2);

    gl_FragColor = vec4(col, 1.0);
}
