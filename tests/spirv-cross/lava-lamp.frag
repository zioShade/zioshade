#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test lava lamp effect with metaballs
float blob(vec2 p, vec2 center, float radius) {
    float d = length(p - center);
    return radius * radius / (d * d + 0.01);
}

void main() {
    vec2 p = uv * 3.0;
    
    float b1 = blob(p, vec2(1.0 + sin(uv.x * 3.0), 1.5 + cos(uv.y * 2.0)), 0.4);
    float b2 = blob(p, vec2(2.0 + cos(uv.y * 4.0), 1.0 + sin(uv.x * 2.5)), 0.5);
    float b3 = blob(p, vec2(1.5 + sin(uv.x * 2.0 + 1.0), 2.0 + cos(uv.y * 3.0 + 0.5)), 0.35);
    
    float field = b1 + b2 + b3;
    
    float is_lava = smoothstep(1.0, 1.5, field);
    
    vec3 bg = vec3(0.1, 0.0, 0.2);
    vec3 lava_hot = vec3(1.0, 0.3, 0.0);
    vec3 lava_bright = vec3(1.0, 0.8, 0.0);
    
    vec3 lava = mix(lava_hot, lava_bright, smoothstep(1.5, 3.0, field));
    vec3 col = mix(bg, lava, is_lava);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
