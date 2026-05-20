#version 310 es
precision highp float;
out vec4 fragColor;

struct Ray {
    vec3 origin;
    vec3 dir;
};

struct Sphere {
    vec3 center;
    float radius;
    vec3 color;
};

float intersect(Ray ray, Sphere sphere) {
    vec3 oc = ray.origin - sphere.center;
    float b = dot(oc, ray.dir);
    float c = dot(oc, oc) - sphere.radius * sphere.radius;
    float disc = b * b - c;
    if (disc < 0.0) return -1.0;
    return -b - sqrt(disc);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Ray ray = Ray(vec3(0.0, 0.0, -3.0), normalize(vec3(uv, 1.0)));
    Sphere s1 = Sphere(vec3(0.0, 0.0, 0.0), 0.8, vec3(0.8, 0.3, 0.2));
    Sphere s2 = Sphere(vec3(0.5, -0.3, 0.5), 0.4, vec3(0.2, 0.3, 0.8));

    float t1 = intersect(ray, s1);
    float t2 = intersect(ray, s2);

    vec3 col = vec3(0.1, 0.1, 0.15);
    if (t1 > 0.0 && (t2 < 0.0 || t1 < t2)) {
        vec3 p = ray.origin + ray.dir * t1;
        vec3 n = normalize(p - s1.center);
        float diff = max(dot(n, normalize(vec3(1.0, 1.0, -1.0))), 0.0);
        col = s1.color * (0.2 + 0.8 * diff);
    } else if (t2 > 0.0) {
        vec3 p = ray.origin + ray.dir * t2;
        vec3 n = normalize(p - s2.center);
        float diff = max(dot(n, normalize(vec3(1.0, 1.0, -1.0))), 0.0);
        col = s2.color * (0.2 + 0.8 * diff);
    }
    fragColor = vec4(col, 1.0);
}
