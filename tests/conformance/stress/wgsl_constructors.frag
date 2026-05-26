// Test: multiple vec/mat constructors
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    // Vec constructors from scalars and other vecs
    vec2 a = vec2(1.0);
    vec3 b = vec3(a, 0.5);
    vec4 c = vec4(b.xy, b.z, 1.0);
    vec4 d = vec4(a, a);
    
    // Mat constructors
    mat2 m2 = mat2(1.0, 2.0, 3.0, 4.0);
    mat3 m3 = mat3(vec3(1.0), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0));
    mat4 m4 = mat4(1.0);
    
    // Diagonal
    vec2 diag = vec2(m2[0].x, m2[1].y);
    
    vec3 transformed = m3 * b;
    float result = dot(c.xy, diag) * transformed.x;
    
    fragColor = vec4(result, d.z, c.w, 1.0);
}
