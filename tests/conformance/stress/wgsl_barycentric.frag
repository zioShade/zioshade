// Test: face culling and winding order simulation
#version 450

layout(location = 0) out vec4 fragColor;

bool isFrontFacing(vec2 v0, vec2 v1, vec2 v2) {
    vec2 e1 = v1 - v0;
    vec2 e2 = v2 - v0;
    float cross = e1.x * e2.y - e1.y * e2.x;
    return cross > 0.0;
}

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    vec2 tri[3];
    tri[0] = vec2(0.2, 0.3);
    tri[1] = vec2(0.8, 0.3);
    tri[2] = vec2(0.5, 0.8);
    
    bool front = isFrontFacing(tri[0], tri[1], tri[2]);
    
    // Check if uv is inside triangle
    vec2 v0 = tri[1] - tri[0];
    vec2 v1 = tri[2] - tri[0];
    vec2 v2 = uv - tri[0];
    
    float d00 = dot(v0, v0);
    float d01 = dot(v0, v1);
    float d11 = dot(v1, v1);
    float d20 = dot(v2, v0);
    float d21 = dot(v2, v1);
    
    float denom = d00 * d11 - d01 * d01;
    float u = (d11 * d20 - d01 * d21) / denom;
    float v = (d00 * d21 - d01 * d20) / denom;
    bool inside = u >= 0.0 && v >= 0.0 && (u + v) <= 1.0;
    
    vec3 color = inside ? (front ? vec3(0.2, 0.6, 0.9) : vec3(0.9, 0.3, 0.2)) : vec3(0.1);
    
    fragColor = vec4(color, 1.0);
}
