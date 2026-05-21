#version 310 es
precision highp float;
out vec4 fragColor;

struct Light3 { vec3 pos; vec3 color; float intensity; };

vec3 shadePoint2(vec3 pos, vec3 normal, Light3 light) {
    vec3 toLight = normalize(light.pos - pos);
    float diff = max(dot(normal, toLight), 0.0);
    float dist = length(light.pos - pos);
    float atten = light.intensity / (dist * dist + 0.1);
    return light.color * diff * atten;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Light3 l1 = Light3(vec3(1.0, 1.0, -1.0), vec3(0.8, 0.6, 0.2), 2.0);
    Light3 l2 = Light3(vec3(-1.0, 0.5, -1.0), vec3(0.2, 0.4, 0.8), 1.5);
    vec3 normal = normalize(vec3(uv, sqrt(max(1.0 - dot(uv, uv), 0.0))));
    vec3 pos = vec3(uv, 0.0);
    vec3 col = shadePoint2(pos, normal, l1) + shadePoint2(pos, normal, l2);
    col += vec3(0.05);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
