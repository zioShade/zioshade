// Test: outerProduct and matrix construction from vectors
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec3 a = vec3(uv, 0.5);
    vec3 b = vec3(1.0, 0.5, 0.0);
    
    mat3 outer = outerProduct(a, b);
    
    vec2 c = vec2(0.3, 0.7);
    vec2 d = vec2(uv.y, uv.x);
    mat2 m2 = outerProduct(c, d);
    
    vec3 transformed = outer * vec3(1.0);
    vec2 t2 = m2 * c;
    
    float result = transformed.x + t2.x;
    fragColor = vec4(result, transformed.y, t2.y, 1.0);
}
