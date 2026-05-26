// Test: uniform buffer with std140 layout
#version 450

layout(std140, binding = 0) uniform Material {
    vec4 baseColor;
    float roughness;
    float metallic;
    float emissive;
    float opacity;
    vec4 emissiveColor;
};

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec3 color = baseColor.rgb;
    color += emissiveColor.rgb * emissive;
    color *= mix(vec3(0.5), vec3(1.0), 1.0 - roughness);
    color = mix(color, vec3(0.5), metallic);
    
    float alpha = opacity;
    if (uv.y > 0.5) alpha *= 0.8;
    
    fragColor = vec4(color, alpha);
}
