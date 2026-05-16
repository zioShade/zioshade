#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// OpSelect test: conditional vector selection
void main() {
    bvec3 cond = bvec3(uv.x > 0.3, uv.y > 0.5, uv.x > uv.y);
    
    vec3 a = vec3(1.0, 0.0, 0.0);
    vec3 b = vec3(0.0, 0.0, 1.0);
    
    // Mix with boolean conditions
    vec3 col;
    col.r = cond.x ? a.r : b.r;
    col.g = cond.y ? a.g : b.g;
    col.b = cond.z ? a.b : b.b;
    
    fragColor = vec4(col, 1.0);
}
