#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test pattern with 4 quadrant split and independent shading
vec3 shadeQuad(vec2 p, int quad) {
    if (quad == 0) return vec3(p.x, p.y, 0.3);
    if (quad == 1) return vec3(0.3, p.x, p.y);
    if (quad == 2) return vec3(p.y, 0.3, p.x);
    return vec3(p.x * p.y, 0.5, 1.0 - p.x * p.y);
}

void main() {
    int qx = uv.x < 0.5 ? 0 : 1;
    int qy = uv.y < 0.5 ? 0 : 1;
    int quad = qy * 2 + qx;
    
    vec2 local = fract(uv * 2.0);
    vec3 col = shadeQuad(local, quad);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
