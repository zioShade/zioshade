#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test picket fence with perspective
void main() {
    vec3 col = vec3(0.5, 0.7, 0.95); // sky
    
    // Ground plane
    float ground = smoothstep(0.6, 0.55, uv.y);
    col = mix(col, vec3(0.35, 0.55, 0.2), ground);
    
    // Fence posts with perspective (get closer together toward horizon)
    float horizon = 0.55;
    float depth = smoothstep(0.15, horizon, uv.y);
    float num_posts = 20.0;
    
    // Perspective-corrected x position
    float persp_x = (uv.x - 0.5) / max(depth, 0.01) + 0.5;
    float post_id = floor(persp_x * num_posts);
    float post_local = fract(persp_x * num_posts);
    
    // Post width varies with depth
    float post_width = mix(0.6, 0.3, depth);
    float post = step(0.1, post_local) * step(post_local, post_width);
    
    // Only show fence above ground, below horizon
    float fence_band = step(0.35, uv.y) * (1.0 - step(horizon, uv.y));
    post *= fence_band;
    
    // Horizontal rails
    float rail1 = smoothstep(0.01, 0.0, abs(uv.y - 0.42)) * fence_band;
    float rail2 = smoothstep(0.01, 0.0, abs(uv.y - 0.5)) * fence_band;
    float rails = max(rail1, rail2);
    
    // Wood color
    vec3 wood_light = vec3(0.75, 0.6, 0.4);
    vec3 wood_dark = vec3(0.5, 0.4, 0.25);
    vec3 wood = mix(wood_dark, wood_light, depth);
    
    col = mix(col, wood, max(post, rails));
    
    // Post shadow
    float shadow = step(uv.x, 0.5 + (persp_x - 0.5) * depth * 0.8) * ground * 0.3;
    col *= 1.0 - shadow * 0.15;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
