#version 430
layout(location = 0) out vec4 FragColor;

// Test: multiple function calls with different arg counts
float saturate(float x) { return clamp(x, 0.0, 1.0); }
vec3 shade(vec3 base, float light) { return base * light; }
vec3 shade(vec3 base, float light, float ao) { return base * light * ao; }

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float l = saturate(uv.x * 1.5);
    float a = saturate(uv.y * 0.8 + 0.2);
    vec3 c1 = shade(vec3(0.8, 0.4, 0.2), l);
    vec3 c2 = shade(vec3(0.2, 0.6, 0.8), l, a);
    FragColor = vec4(mix(c1, c2, 0.5), 1.0);
}
