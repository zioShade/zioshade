#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test chemical atom / molecular structure
void main() {
    vec3 col = vec3(0.02, 0.02, 0.06);
    
    // Central atom (large)
    float d_center = length(uv - vec2(0.5, 0.5));
    float atom_center = smoothstep(0.07, 0.06, d_center);
    float highlight_c = exp(-length(uv - vec2(0.48, 0.52)) * 30.0) * atom_center;
    col += atom_center * vec3(0.3, 0.5, 0.8) + highlight_c * vec3(0.3);
    
    // Surrounding atoms (6 in a hexagonal arrangement)
    float bonds = 0.0;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float angle = fi * 1.0472 - 1.5708;
        vec2 atom_pos = vec2(0.5, 0.5) + vec2(cos(angle), sin(angle)) * 0.2;
        
        // Bond line from center to atom
        vec2 dir = normalize(atom_pos - vec2(0.5, 0.5));
        float proj = dot(uv - vec2(0.5, 0.5), dir);
        float perp = abs(dot(uv - vec2(0.5, 0.5), vec2(-dir.y, dir.x)));
        float bond = smoothstep(0.005, 0.002, perp) * step(0.07, proj) * smoothstep(0.19, 0.17, proj);
        bonds += bond;
        
        // Atom (smaller, colored)
        float d_atom = length(uv - atom_pos);
        float atom_shape = smoothstep(0.04, 0.035, d_atom);
        float hl = exp(-length(uv - (atom_pos + vec2(-0.008, 0.008))) * 50.0) * atom_shape * 0.3;
        
        // Different colors per atom
        vec3 atom_col;
        if (i < 2) atom_col = vec3(0.8, 0.3, 0.2);
        else if (i < 4) atom_col = vec3(0.3, 0.7, 0.3);
        else atom_col = vec3(0.9, 0.8, 0.2);
        
        col = mix(col, atom_col, atom_shape) + hl;
    }
    
    col += bonds * vec3(0.4, 0.4, 0.5);
    
    // Electron orbit rings
    float orbit = smoothstep(0.003, 0.001, abs(length(uv - vec2(0.5, 0.5)) - 0.35));
    float orbit_mask = step(0.0, cos(a * 2.0 + 0.5));
    col += orbit * orbit_mask * vec3(0.15, 0.15, 0.25);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
