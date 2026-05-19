#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test kintsugi pattern (golden repair on broken ceramic)
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5);
}

void main() {
    vec3 col;
    
    // Ceramic shard regions
    vec2 p = uv * 4.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Voronoi-like cracks between shards
    float min_dist = 1.0;
    vec2 nearest_id = id;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 neighbor = vec2(float(x), float(y));
            vec2 cell_id = id + neighbor;
            vec2 point = hash(cell_id) * 0.6 + 0.2;
            vec2 diff = neighbor + point - fp;
            float d = length(diff);
            if (d < min_dist) {
                min_dist = d;
                nearest_id = cell_id;
            }
        }
    }
    
    // Crack edges (where min_dist is small)
    float crack = smoothstep(0.08, 0.03, min_dist);
    
    // Ceramic color (per-cell variation)
    float h = hash(nearest_id);
    vec3 ceramic = mix(vec3(0.85, 0.82, 0.78), vec3(0.75, 0.72, 0.68), h);
    
    // Celadon-like glaze
    float glaze = smoothstep(0.3, 0.7, h) * 0.2;
    ceramic += vec3(-0.05, 0.05, 0.08) * glaze;
    
    col = ceramic;
    
    // Kintsugi: gold along the cracks
    vec3 gold = vec3(0.85, 0.65, 0.2);
    float gold_line = smoothstep(0.06, 0.02, min_dist) * (1.0 - smoothstep(0.02, 0.0, min_dist));
    col = mix(col, gold, gold_line);
    
    // Gold highlight
    float gold_hl = exp(-min_dist * 40.0) * crack * 0.3;
    col += gold_hl * gold;
    
    // Subtle ceramic texture
    float tex = hash(floor(uv * 200.0)) * 0.02;
    col += tex;
    
    // Vignette
    float vig = 1.0 - dot(uv - 0.5, uv - 0.5) * 0.5;
    col *= vig;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
