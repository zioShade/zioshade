// Test: nested struct arrays with function pass-through
#version 450

layout(location = 0) out vec4 fragColor;

struct Ray {
    vec3 origin;
    vec3 direction;
};

struct Hit {
    float t;
    int id;
    vec3 normal;
};

Hit intersectSphere(Ray ray, vec3 center, float radius) {
    Hit h;
    h.t = -1.0;
    h.id = -1;
    h.normal = vec3(0.0);
    
    vec3 oc = ray.origin - center;
    float a = dot(ray.direction, ray.direction);
    float b = 2.0 * dot(oc, ray.direction);
    float c = dot(oc, oc) - radius * radius;
    float disc = b * b - 4.0 * a * c;
    
    if (disc > 0.0) {
        float sqrtDisc = sqrt(disc);
        float t0 = (-b - sqrtDisc) / (2.0 * a);
        float t1 = (-b + sqrtDisc) / (2.0 * a);
        if (t0 > 0.001) {
            h.t = t0;
            h.id = 0;
            h.normal = normalize(ray.origin + ray.direction * t0 - center);
        } else if (t1 > 0.001) {
            h.t = t1;
            h.id = 0;
            h.normal = normalize(ray.origin + ray.direction * t1 - center);
        }
    }
    return h;
}

void main() {
    vec2 uv = (gl_FragCoord.xy / vec2(800.0, 600.0)) * 2.0 - 1.0;
    
    Ray r;
    r.origin = vec3(0.0, 0.0, 5.0);
    r.direction = normalize(vec3(uv, -1.0));
    
    vec3 centers[3];
    centers[0] = vec3(-2.0, 0.0, 0.0);
    centers[1] = vec3(0.0, 0.0, 0.0);
    centers[2] = vec3(2.0, 0.0, 0.0);
    
    Hit closest;
    closest.t = 1e10;
    closest.id = -1;
    
    for (int i = 0; i < 3; i++) {
        Hit h = intersectSphere(r, centers[i], 1.0);
        if (h.t > 0.0 && h.t < closest.t) {
            closest = h;
        }
    }
    
    vec3 color = vec3(0.1);
    if (closest.t < 1e10) {
        vec3 lightDir = normalize(vec3(1.0, 1.0, 1.0));
        float diff = max(dot(closest.normal, lightDir), 0.0);
        color = vec3(diff) * vec3(0.8, 0.5, 0.3);
    }
    
    fragColor = vec4(color, 1.0);
}
