#version 310 es
precision highp float;
out vec4 fragColor;

struct Material {
    vec3 base_color;
    float roughness;
    float metallic;
};

struct PointLight {
    vec3 position;
    float intensity;
    vec3 color;
};

vec3 evaluate(Material mat, PointLight light, vec3 pos) {
    float d = length(pos - light.position);
    float atten = light.intensity / (d * d + 0.01);
    vec3 diffuse = mat.base_color * (1.0 - mat.metallic);
    vec3 specular = mix(vec3(0.04), mat.base_color, mat.metallic);
    float spec_pow = mix(256.0, 16.0, mat.roughness);
    return (diffuse + specular * pow(atten, spec_pow)) * light.color * atten;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 pos = vec3(uv, 0.0);
    Material gold = Material(vec3(1.0, 0.76, 0.34), 0.3, 0.9);
    Material plastic = Material(vec3(0.2, 0.5, 0.8), 0.7, 0.0);
    PointLight l1 = PointLight(vec3(-0.5, 0.5, 1.0), 2.0, vec3(1.0, 0.95, 0.8));
    PointLight l2 = PointLight(vec3(0.5, -0.3, 0.8), 1.5, vec3(0.8, 0.9, 1.0));
    // Split screen: gold vs plastic
    vec3 col = uv.x < 0.0 ?
        evaluate(gold, l1, pos) + evaluate(gold, l2, pos) :
        evaluate(plastic, l1, pos) + evaluate(plastic, l2, pos);
    col = min(col, vec3(1.0));
    fragColor = vec4(col, 1.0);
}
