#version 310 es
precision highp float;
out vec4 fragColor;

struct Material { vec3 color; float roughness; };
struct Sphere { vec3 center; float radius; Material mat; };

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Sphere s1 = Sphere(vec3(3.0, 5.0, 0.0), 1.5, Material(vec3(0.8, 0.3, 0.2), 0.5));
    Sphere s2 = Sphere(vec3(7.0, 5.0, 0.0), 1.2, Material(vec3(0.2, 0.3, 0.8), 0.3));
    
    float d1 = length(uv - s1.center.xy) - s1.radius;
    float d2 = length(uv - s2.center.xy) - s2.radius;
    
    vec3 col = vec3(0.1);
    if (d1 < 0.0) {
        float shade = 0.5 + 0.5 * (1.0 - s1.mat.roughness) * (-d1);
        col = s1.mat.color * shade;
    }
    if (d2 < 0.0 && d2 > d1) {
        float shade = 0.5 + 0.5 * (1.0 - s2.mat.roughness) * (-d2);
        col = s2.mat.color * shade;
    }
    fragColor = vec4(col, 1.0);
}
