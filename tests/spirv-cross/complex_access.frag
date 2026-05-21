#version 310 es
precision highp float;
out vec4 fragColor;

// Test: struct accessed through nested conditionals
struct Material2 { vec3 albedo; float roughness; float metallic; };

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    Material2 mat;
    if (r < 0.3) {
        mat.albedo = vec3(0.8, 0.2, 0.1);
        mat.roughness = 0.1;
        mat.metallic = 1.0;
    } else if (r < 0.6) {
        mat.albedo = vec3(0.1, 0.7, 0.3);
        mat.roughness = 0.5;
        mat.metallic = 0.0;
    } else {
        mat.albedo = vec3(0.3, 0.3, 0.8);
        mat.roughness = 0.9;
        mat.metallic = 0.5;
    }
    // Use struct members in complex expression
    vec3 col = mat.albedo * (1.0 - mat.metallic) + vec3(0.04) * mat.metallic;
    col *= 0.5 + 0.5 * mat.roughness;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
