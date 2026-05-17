#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test nested function calls with struct return
struct Ray {
    vec3 origin;
    vec3 dir;
};

Ray createRay(vec2 screen_uv) {
    Ray r;
    r.origin = vec3(screen_uv * 2.0 - 1.0, 0.0);
    r.dir = normalize(vec3(0.0, 0.0, 1.0));
    return r;
}

vec3 pointOnRay(Ray r, float t) {
    return r.origin + r.dir * t;
}

void main() {
    Ray r = createRay(uv);
    vec3 p = pointOnRay(r, 1.0);
    
    fragColor = vec4(clamp(p * 0.5 + 0.5, 0.0, 1.0), 1.0);
}
