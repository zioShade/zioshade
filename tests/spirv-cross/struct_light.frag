#version 310 es
precision highp float;
out vec4 fragColor;

struct Light {
    vec3 pos;
    vec3 color;
    float intensity;
};

vec3 shade(vec3 pos, Light light) {
    float d = length(pos - light.pos);
    float atten = light.intensity / (d * d + 0.01);
    return light.color * atten;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    vec3 pos = vec3(uv, 0.0);
    Light l1 = Light(vec3(-0.5, 0.5, 1.0), vec3(1.0, 0.5, 0.2), 2.0);
    Light l2 = Light(vec3(0.5, -0.3, 0.8), vec3(0.2, 0.5, 1.0), 1.5);
    vec3 col = shade(pos, l1) + shade(pos, l2);
    col = min(col, vec3(1.0));
    fragColor = vec4(col, 1.0);
}
