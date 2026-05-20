#version 310 es
precision highp float;
out vec4 fragColor;

// Test: forward function with struct parameter
struct Light2 { vec3 pos; vec3 color; float intensity; };

vec3 shade2(Light2 l, vec3 normal) {
    vec3 light_dir = normalize(l.pos);
    float diff = max(dot(normal, light_dir), 0.0);
    return l.color * diff * l.intensity;
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Light2 l = Light2(vec3(1.0, 1.0, 1.0), vec3(0.8, 0.6, 0.2), 1.5);
    vec3 normal = normalize(vec3(uv, sqrt(max(1.0 - dot(uv, uv), 0.0))));
    vec3 col = shade2(l, normal);
    col = clamp(col, 0.0, 1.0);
    fragColor = vec4(col, 1.0);
}
