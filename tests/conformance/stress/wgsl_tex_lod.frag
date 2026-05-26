// Test: sampler state and texture lod
#version 450

layout(binding = 0) uniform sampler2D uTex;
layout(binding = 1) uniform sampler2DArray uTexArray;
layout(binding = 2) uniform sampler3D uTex3D;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    // Basic sampling
    vec4 c1 = texture(uTex, uv);
    vec4 c2 = textureLod(uTex, uv, 2.0);
    vec4 c3 = textureOffset(uTex, uv, ivec2(1, 1));
    
    // Array texture
    vec4 c4 = texture(uTexArray, vec3(uv, 0.0));
    
    // 3D texture
    vec4 c5 = texture(uTex3D, vec3(uv, 0.5));
    
    // Texture size queries
    vec2 sz = textureSize(uTex, 0);
    
    fragColor = c1 + c2 * 0.1 + c3 * 0.1 + vec4(sz / 1024.0, 0.0, 1.0);
}
