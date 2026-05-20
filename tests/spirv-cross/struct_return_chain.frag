#version 310 es
precision highp float;
out vec4 fragColor;

struct Ray {
    vec3 origin;
    vec3 dir;
};

struct Hit {
    float t;
    vec3 normal;
    int id;
};

Hit intersect(Ray r, int id) {
    Hit h;
    h.t = length(r.dir);
    h.normal = normalize(r.dir);
    h.id = id;
    return h;
}

void main() {
    Ray r;
    r.origin = vec3(0.0);
    r.dir = vec3(gl_FragCoord.xy, 1.0);
    Hit h = intersect(r, 1);
    vec3 col = h.normal * h.t * 0.1;
    fragColor = vec4(col, 1.0);
}
