#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test lava texture with turbulence
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1,0)), f.x),
               mix(hash(i + vec2(0,1)), hash(i + vec2(1,1)), f.x), f.y);
}

float fbm(vec2 p) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += noise(p) * amp;
        p *= 2.1;
        amp *= 0.5;
    }
    return val;
}

void main() {
    float n = fbm(uv * 4.0);
    float n2 = fbm(uv * 6.0 + 10.0);
    
    float heat = n * 0.7 + n2 * 0.3;
    
    // Lava color palette
    vec3 cold = vec3(0.1, 0.0, 0.0);
    vec3 warm = vec3(0.6, 0.1, 0.0);
    vec3 hot = vec3(1.0, 0.5, 0.0);
    vec3 bright = vec3(1.0, 0.9, 0.3);
    
    vec3 col;
    if (heat < 0.35) col = mix(cold, warm, heat / 0.35);
    else if (heat < 0.55) col = mix(warm, hot, (heat - 0.35) / 0.2);
    else col = mix(hot, bright, clamp((heat - 0.55) / 0.2, 0.0, 1.0));
    
    fragColor = vec4(col, 1.0);
}
