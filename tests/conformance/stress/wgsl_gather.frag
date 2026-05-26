// Test: gather operation
#version 450

layout(binding = 0) uniform sampler2D uTex;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec4 gathered = textureGather(uTex, uv, 0);
    vec4 normal = texture(uTex, uv);
    
    fragColor = gathered * 0.5 + normal * 0.5;
}
