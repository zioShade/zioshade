#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test boolean vector operations
void main() {
    vec3 a = vec3(uv.x, uv.y, uv.x + uv.y);
    vec3 b = vec3(0.3, 0.5, 0.7);
    
    bvec3 lt = lessThan(a, b);
    bvec3 gt = greaterThan(a, b);
    bvec3 eq = equal(a, b);
    bvec3 ne = notEqual(a, b);
    
    // any / all
    float any_lt = any(lt) ? 1.0 : 0.0;
    float all_gt = all(gt) ? 1.0 : 0.0;
    float any_eq = any(eq) ? 1.0 : 0.0;
    float any_ne = any(ne) ? 1.0 : 0.0;
    
    fragColor = vec4(any_lt, all_gt, any_eq + any_ne * 0.5, 1.0);
}
