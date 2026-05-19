#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Koch snowflake fractal pattern
float kochSDF(vec2 p, int depth) {
    float d = 1e10;
    float scale = 1.0;
    float angle = 0.0;
    
    // Start with equilateral triangle edges
    for (int iter = 0; iter < 4; iter++) {
        // Three sides of equilateral triangle
        for (int side = 0; side < 3; side++) {
            float sa = float(side) * 2.0944 - 1.5708;
            vec2 a = vec2(cos(sa), sin(sa)) * 0.35;
            vec2 b = vec2(cos(sa + 2.0944), sin(sa + 2.0944)) * 0.35;
            
            // Line segment distance
            vec2 pa = p - a;
            vec2 ba = b - a;
            float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            float ld = length(pa - ba * t);
            d = min(d, ld);
        }
        
        // Iterative Koch: each segment splits into 4 with a bump
        scale *= 3.0;
    }
    
    return d;
}

void main() {
    vec2 p = uv - 0.5;
    
    // Simplified Koch snowflake using triangular distance
    // Use 3 iterations of recursive triangles
    float d = 1.0;
    
    // Level 0: big triangle
    for (int i = 0; i < 3; i++) {
        float a1 = float(i) * 2.0944 - 1.5708;
        float a2 = a1 + 2.0944;
        vec2 v1 = vec2(cos(a1), sin(a1)) * 0.35;
        vec2 v2 = vec2(cos(a2), sin(a2)) * 0.35;
        vec2 pa = p - v1;
        vec2 ba = v2 - v1;
        float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        d = min(d, length(pa - ba * t));
    }
    
    // Level 1: smaller triangular bumps on each edge
    for (int i = 0; i < 3; i++) {
        float a1 = float(i) * 2.0944 - 1.5708;
        float a2 = a1 + 2.0944;
        vec2 v1 = vec2(cos(a1), sin(a1)) * 0.35;
        vec2 v2 = vec2(cos(a2), sin(a2)) * 0.35;
        vec2 mid = (v1 + v2) * 0.5;
        vec2 out_dir = normalize(mid) * 0.12;
        vec2 peak = mid + out_dir;
        
        vec2 pa = p - v1;
        vec2 ba = (mid - out_dir * 0.5) - v1;
        float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        d = min(d, length(pa - ba * t));
        
        pa = p - (mid - out_dir * 0.5);
        ba = peak - (mid - out_dir * 0.5);
        t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        d = min(d, length(pa - ba * t));
        
        pa = p - peak;
        ba = (mid + out_dir * 0.5) - peak;
        t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        d = min(d, length(pa - ba * t));
        
        pa = p - (mid + out_dir * 0.5);
        ba = v2 - (mid + out_dir * 0.5);
        t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        d = min(d, length(pa - ba * t));
    }
    
    float snowflake = smoothstep(0.008, 0.003, d);
    
    vec3 bg = vec3(0.05, 0.08, 0.15);
    vec3 flake = vec3(0.85, 0.92, 1.0);
    
    // Inner glow
    float glow = exp(-d * 8.0) * 0.15;
    
    vec3 col = bg + snowflake * flake + glow * vec3(0.4, 0.6, 0.9);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
