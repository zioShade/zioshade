#version 450

// Test struct passed as function parameter
struct Ray {
    vec3 origin;
    vec3 direction;
};

struct Hit {
    float t;
    vec3 normal;
    int id;
};

Hit intersect(Ray r, int id) {
    Hit h;
    h.t = length(r.direction);
    h.normal = normalize(r.direction);
    h.id = id;
    return h;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    Ray r;
    r.origin = vec3(0.0);
    r.direction = vec3(uv, 1.0);
    Hit h = intersect(r, 42);
    gl_FragColor = vec4(h.normal * 0.5 + 0.5, 1.0);
}
