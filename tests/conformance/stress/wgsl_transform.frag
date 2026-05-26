// Test: nested struct with mat3 and bool logic
#version 450

layout(location = 0) out vec4 fragColor;

struct Transform {
    mat3 rotation;
    vec3 translation;
    float scale;
};

vec3 applyTransform(Transform t, vec3 p) {
    return t.rotation * (p * t.scale) + t.translation;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    Transform t;
    float angle = uv.x * 3.14159;
    float c = cos(angle);
    float s = sin(angle);
    t.rotation = mat3(c, s, 0.0, -s, c, 0.0, 0.0, 0.0, 1.0);
    t.translation = vec3(0.5, 0.5, 0.0);
    t.scale = 0.5 + uv.y * 0.5;
    
    vec3 p = vec3(uv * 2.0 - 1.0, 0.0);
    vec3 transformed = applyTransform(t, p);
    
    bool inside = all(lessThan(abs(transformed), vec3(1.0)));
    bool nearCenter = length(transformed.xy) < 0.3;
    
    vec3 color = inside ? vec3(0.5, 0.7, 0.9) : vec3(0.1, 0.1, 0.15);
    if (nearCenter) color *= 1.5;
    
    fragColor = vec4(color, 1.0);
}
