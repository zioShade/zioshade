// Test: motion blur effect
#version 450

layout(binding = 0) uniform sampler2D uScene;
layout(binding = 1) uniform sampler2D uVelocity;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec2 velocity = texture(uVelocity, uv).xy * 0.1;
    
    vec4 color = vec4(0.0);
    int samples = 8;
    
    for (int i = 0; i < 8; i++) {
        float t = float(i) / float(samples - 1);
        vec2 offset = velocity * (t - 0.5);
        color += texture(uScene, uv + offset);
    }
    
    fragColor = color / float(samples);
}
