#version 310 es
precision highp float;
out vec4 fragColor;

struct Material { vec3 color; float roughness; };

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Material m1 = Material(vec3(0.8, 0.3, 0.2), 0.5);
    Material m2 = Material(vec3(0.2, 0.3, 0.8), 0.3);
    
    float d1 = length(uv - vec2(-0.3, 0.0)) - 0.5;
    float d2 = length(uv - vec2(0.3, 0.0)) - 0.4;
    
    vec3 col = vec3(0.1);
    if (d1 < 0.0) {
        float shade = 0.5 + 0.5 * m1.roughness;
        col = m1.color * shade;
    } else if (d2 < 0.0) {
        float shade = 0.5 + 0.5 * m2.roughness;
        col = m2.color * shade;
    }
    fragColor = vec4(col, 1.0);
}
