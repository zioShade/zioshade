#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test lighthouse with light beams
void main() {
    // Sky gradient (dusk)
    vec3 sky_low = vec3(0.8, 0.5, 0.3);
    vec3 sky_high = vec3(0.15, 0.2, 0.4);
    vec3 col = mix(sky_low, sky_high, uv.y);
    
    // Stars
    float star = step(0.998, fract(sin(dot(floor(uv * 250.0), vec2(12.9, 78.2))) * 43758.5));
    col += star * vec3(0.7) * smoothstep(0.4, 0.6, uv.y);
    
    // Ocean
    float ocean_line = 0.25;
    float ocean = step(uv.y, ocean_line);
    vec3 water_col = vec3(0.08, 0.15, 0.3);
    col = mix(col, water_col, ocean);
    
    // Water waves
    float wave = sin(uv.x * 30.0) * 0.003;
    float wave_line = smoothstep(0.003, 0.001, abs(uv.y - (ocean_line - 0.03 + wave)));
    col += wave_line * vec3(0.15, 0.25, 0.4) * ocean;
    
    // Lighthouse tower (tapered)
    float tower_base = 0.04;
    float tower_top = 0.025;
    float tower_h = 0.35;
    float tower_bottom = 0.1;
    float t = (uv.y - tower_bottom) / tower_h;
    float tower_width = mix(tower_base, tower_top, t);
    float tower_center = 0.7;
    float tower = smoothstep(tower_width, tower_width - 0.003, abs(uv.x - tower_center)) * step(tower_bottom, uv.y) * step(uv.y, tower_bottom + tower_h);
    
    // Red/white stripes
    float stripe = step(0.5, fract(t * 5.0));
    vec3 red_stripe = vec3(0.8, 0.15, 0.1);
    vec3 white_stripe = vec3(0.9, 0.88, 0.85);
    vec3 tower_col = mix(red_stripe, white_stripe, stripe);
    col = mix(col, tower_col, tower);
    
    // Lantern room at top
    float lantern_y = tower_bottom + tower_h;
    float lantern = smoothstep(0.04, 0.035, abs(uv.x - tower_center)) * step(lantern_y, uv.y) * step(uv.y, lantern_y + 0.04);
    col = mix(col, vec3(0.3, 0.3, 0.35), lantern);
    
    // Light beam (rotating cone)
    float light_y = lantern_y + 0.02;
    vec2 lp = uv - vec2(tower_center, light_y);
    float beam_a = atan(lp.x, -lp.y);
    float beam = smoothstep(0.15, 0.05, abs(beam_a)) * step(0.0, -lp.y) * smoothstep(0.7, 0.1, length(lp));
    col += beam * vec3(1.0, 0.95, 0.7) * 0.4;
    
    // Light glow
    float glow = exp(-length(uv - vec2(tower_center, light_y)) * 15.0);
    col += glow * vec3(1.0, 0.9, 0.5) * 0.5;
    
    // Rocks at base
    float rocks = smoothstep(0.15, 0.08, abs(uv.x - 0.7)) * step(uv.y, 0.12) * step(0.05, uv.y);
    col = mix(col, vec3(0.25, 0.22, 0.2), rocks);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
