#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test lotus flower with layered petals
void main() {
    vec2 p = uv - vec2(0.5, 0.45);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Water background
    vec3 col = vec3(0.1, 0.2, 0.3);
    float water_tex = sin(uv.x * 25.0 + uv.y * 15.0) * 0.02;
    col += water_tex;
    
    // Lily pad (flat circle)
    float pad = smoothstep(0.35, 0.34, r) * (1.0 - smoothstep(0.33, 0.32, r)) * step(0.0, p.y);
    float pad_fill = smoothstep(0.34, 0.33, r) * step(0.0, p.y);
    vec3 pad_col = vec3(0.2, 0.45, 0.15);
    float pad_vein = smoothstep(0.005, 0.002, abs(sin(a * 6.0))) * pad_fill * 0.15;
    col = mix(col, pad_col + pad_vein, pad_fill);
    
    // Lotus petals: 3 layers with different sizes
    float petal_total = 0.0;
    
    // Outer petals (8 petals, wide, pointing outward)
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float pa = fi * 0.7854 - 1.5708; // 2*PI/8
        vec2 petal_dir = vec2(cos(pa), sin(pa));
        vec2 perp_dir = vec2(-petal_dir.y, petal_dir.x);
        float along = dot(p, petal_dir);
        float across = abs(dot(p, perp_dir));
        // Petal shape: elliptical
        float petal_w = 0.04;
        float petal_l = 0.18;
        float shape = smoothstep(petal_w, petal_w - 0.01, across * (1.0 + along * 0.5));
        shape *= step(0.0, along) * smoothstep(petal_l, petal_l - 0.02, along);
        float existing = petal_total;
        petal_total = max(petal_total, shape);
    }
    
    // Middle petals (6 petals, slightly different angle)
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float pa = fi * 1.0472 - 1.5708 + 0.2618;
        vec2 petal_dir = vec2(cos(pa), sin(pa));
        vec2 perp_dir = vec2(-petal_dir.y, petal_dir.x);
        float along = dot(p, petal_dir);
        float across = abs(dot(p, perp_dir));
        float petal_w = 0.035;
        float petal_l = 0.13;
        float shape = smoothstep(petal_w, petal_w - 0.008, across * (1.0 + along * 0.5));
        shape *= step(0.0, along) * smoothstep(petal_l, petal_l - 0.015, along);
        petal_total = max(petal_total, shape);
    }
    
    // Inner petals (4 petals)
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float pa = fi * 1.5708 - 1.5708;
        vec2 petal_dir = vec2(cos(pa), sin(pa));
        vec2 perp_dir = vec2(-petal_dir.y, petal_dir.x);
        float along = dot(p, petal_dir);
        float across = abs(dot(p, perp_dir));
        float petal_w = 0.03;
        float petal_l = 0.08;
        float shape = smoothstep(petal_w, petal_w - 0.005, across * (1.0 + along * 0.3));
        shape *= step(0.0, along) * smoothstep(petal_l, petal_l - 0.01, along);
        petal_total = max(petal_total, shape);
    }
    
    // Petal colors: white to pink gradient
    float depth = smoothstep(0.15, 0.02, r);
    vec3 white = vec3(0.95, 0.93, 0.95);
    vec3 pink = vec3(0.95, 0.7, 0.8);
    vec3 petal_col = mix(white, pink, depth);
    
    col = mix(col, petal_col, petal_total);
    
    // Center (yellow stamen)
    float center = smoothstep(0.03, 0.02, r);
    col = mix(col, vec3(0.95, 0.85, 0.2), center);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
