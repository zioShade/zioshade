// Tests: struct with vec3 array, conditional modification in nested loop
// Aggressively tests AccessChain + branchMergePhi interaction
precision mediump float;
uniform vec2 u_resolution;

struct Palette {
    vec3 entries[4];
    int count;
};

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Palette p;
    p.entries[0] = vec3(0.1, 0.2, 0.3);
    p.entries[1] = vec3(0.4, 0.5, 0.6);
    p.entries[2] = vec3(0.7, 0.8, 0.9);
    p.entries[3] = vec3(1.0, 0.0, 0.5);
    p.count = 4;
    
    // Modify entries conditionally based on uv position
    for (int i = 0; i < 3; i++) {
        if (uv.x > float(i) * 0.25) {
            p.entries[i] *= vec3(uv.y, 1.0 - uv.y, 0.5);
        }
        if (uv.y > 0.5) {
            p.entries[i + 1].x += 0.1;
        }
    }
    
    // Read based on uv
    int idx = int(uv.x * 3.999);
    idx = clamp(idx, 0, 3);
    vec3 col = p.entries[idx];
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
