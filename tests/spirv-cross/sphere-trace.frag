#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Sphere tracing SDF
float sdSphere(vec3 p, float r) { return length(p) - r; }
float sdPlane(vec3 p) { return p.y + 0.5; }

float scene(vec3 p) {
    float sphere = sdSphere(p - vec3(0.0, 0.0, 2.0), 0.8);
    float plane = sdPlane(p);
    return min(sphere, plane);
}

vec3 getNormal(vec3 p) {
    float eps = 0.001;
    float d = scene(p);
    vec3 n = vec3(
        scene(p + vec3(eps, 0, 0)) - d,
        scene(p + vec3(0, eps, 0)) - d,
        scene(p + vec3(0, 0, eps)) - d
    );
    return normalize(n);
}

void main() {
    vec3 ro = vec3(uv * 2.0 - 1.0, 0.0);  // ray origin
    vec3 rd = vec3(0.0, 0.0, 1.0);         // ray direction
    
    float t = 0.0;
    for (int i = 0; i < 32; i++) {
        vec3 p = ro + rd * t;
        float d = scene(p);
        if (d < 0.001) break;
        t += d;
        if (t > 10.0) break;
    }
    
    vec3 col = vec3(0.05);
    if (t < 10.0) {
        vec3 p = ro + rd * t;
        vec3 n = getNormal(p);
        vec3 light = normalize(vec3(1.0, 1.0, -0.5));
        float diff = max(dot(n, light), 0.0);
        col = vec3(0.6, 0.4, 0.3) * (diff * 0.8 + 0.2);
    }
    
    fragColor = vec4(col, 1.0);
}
