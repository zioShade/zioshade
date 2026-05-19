#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test hot air balloon with striped envelope
void main() {
    // Sky gradient
    vec3 col = mix(vec3(0.7, 0.8, 0.95), vec3(0.3, 0.5, 0.8), uv.y);
    
    // Clouds
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float cx = fract(sin(fi * 7.3) * 43.7);
        float cy = 0.7 + fract(cos(fi * 11.1) * 37.9) * 0.2;
        float cd = length((uv - vec2(cx, cy)) * vec2(0.6, 1.0));
        float cloud = smoothstep(0.08, 0.03, cd);
        col = mix(col, vec3(0.95, 0.96, 0.98), cloud * 0.6);
    }
    
    // Balloon center
    vec2 center = vec2(0.5, 0.58);
    vec2 p = uv - center;
    
    // Envelope (sphere shape)
    vec2 ep = p * vec2(1.0, 1.3);
    float r = length(ep);
    float envelope = smoothstep(0.22, 0.215, r);
    
    // Vertical stripes
    float a = atan(p.y, p.x);
    float stripes = step(0.0, sin(a * 5.0));
    
    // Horizontal bands
    float bands = step(0.5, fract(p.y * 8.0));
    
    vec3 red = vec3(0.85, 0.15, 0.1);
    vec3 yellow = vec3(0.95, 0.8, 0.1);
    vec3 white = vec3(0.95, 0.93, 0.9);
    
    vec3 env_col = mix(red, yellow, stripes);
    env_col = mix(env_col, white, bands * 0.3);
    
    // Shading
    float shade = smoothstep(0.2, 0.0, r) * 0.4 + 0.6;
    env_col *= shade;
    
    // Highlight
    float hl = exp(-dot(p - vec2(-0.05, 0.05), p - vec2(-0.05, 0.05)) * 50.0) * 0.3;
    env_col += hl;
    
    col = mix(col, env_col, envelope);
    
    // Basket
    float basket_y = 0.33;
    float basket = smoothstep(0.04, 0.035, abs(uv.x - center.x)) * step(basket_y - 0.03, uv.y) * step(uv.y, basket_y);
    float basket_rim = smoothstep(0.05, 0.045, abs(uv.x - center.x)) * smoothstep(basket_y + 0.003, basket_y, uv.y) * step(basket_y - 0.03, uv.y) * step(uv.y, basket_y + 0.005);
    vec3 basket_col = vec3(0.6, 0.4, 0.2);
    col = mix(col, basket_col, max(basket, basket_rim));
    
    // Ropes from envelope bottom to basket
    float ropes = 0.0;
    float env_bottom = center.y - 0.17;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float top_x = center.x + (fi - 1.5) * 0.015;
        float bot_x = center.x + (fi - 1.5) * 0.025;
        float ry = clamp((uv.y - basket_y) / (env_bottom - basket_y), 0.0, 1.0);
        float rx = mix(bot_x, top_x, ry);
        ropes += smoothstep(0.003, 0.001, abs(uv.x - rx));
    }
    ropes *= step(basket_y, uv.y) * smoothstep(env_bottom + 0.01, env_bottom, uv.y) * (1.0 - envelope);
    col += min(ropes, 1.0) * vec3(0.35, 0.25, 0.15);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
