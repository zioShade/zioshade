// Tests: nested struct with function calls, conditional assignment
// Previously broken: AccessChains into nested struct across branches
precision mediump float;
uniform vec2 u_resolution;

struct Material {
    vec3 color;
    float roughness;
};

struct Sphere {
    vec3 center;
    float radius;
    Material mat;
};

Sphere createSphere(float x, float y, float r) {
    Sphere s;
    s.center = vec3(x, y, 0.0);
    s.radius = r;
    s.mat.color = vec3(0.8, 0.2, 0.1);
    s.mat.roughness = 0.5;
    return s;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Sphere s1 = createSphere(0.3, 0.5, 0.2);
    Sphere s2 = createSphere(0.7, 0.5, 0.3);
    
    vec3 col;
    if (uv.x > 0.5) {
        col = s1.mat.color * (1.0 - length(uv - s1.center.xy));
    } else {
        col = s2.mat.color * (1.0 - length(uv - s2.center.xy));
    }
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
