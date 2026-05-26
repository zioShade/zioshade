// Test: cube map sampling
#version 450

layout(binding = 0) uniform samplerCube uCube;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    vec3 dir = normalize(vec3(uv * 2.0 - 1.0, 1.0));
    
    vec4 color = texture(uCube, dir);
    vec4 lod = textureLod(uCube, dir, 2.0);
    
    fragColor = color + lod * 0.1;
}
