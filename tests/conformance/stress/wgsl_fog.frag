// Test: depth-based fog effect
#version 450

layout(binding = 0) uniform sampler2D uDepthTex;
layout(binding = 1) uniform sampler2D uColorTex;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec4 color = texture(uColorTex, uv);
    float depth = texture(uDepthTex, uv).r;
    
    vec3 fogColor = vec3(0.7, 0.8, 0.9);
    float fogDensity = 2.0;
    float fogFactor = 1.0 - exp(-fogDensity * depth * depth);
    fogFactor = clamp(fogFactor, 0.0, 1.0);
    
    vec3 result = mix(color.rgb, fogColor, fogFactor);
    fragColor = vec4(result, color.a);
}
