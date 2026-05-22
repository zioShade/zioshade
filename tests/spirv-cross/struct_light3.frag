#version 310 es
precision highp float;
out vec4 fragColor;

// Complex: nested function calls with struct returns, loops, conditionals
struct Light {
    vec3 color;
    float intensity;
};

struct Material {
    vec3 albedo;
    float roughness;
};

vec3 shadePoint(vec2 p, Light l, Material m) {
    float d = length(p);
    vec3 col = l.color * m.albedo * l.intensity;
    if (d < 0.3) {
        col *= 1.5;
    } else {
        col *= max(0.3, 1.0 - d);
    }
    return col;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Light lights[2];
    lights[0].color = vec3(1.0, 0.8, 0.6);
    lights[0].intensity = 1.0;
    lights[1].color = vec3(0.4, 0.6, 1.0);
    lights[1].intensity = 0.7;

    Material mat;
    mat.albedo = vec3(0.8);
    mat.roughness = 0.5;

    vec3 col = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        vec2 lp = vec2(float(i) * 0.5 + 0.25, 0.5);
        col += shadePoint(uv - lp, lights[i], mat);
    }

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
