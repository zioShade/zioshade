#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test city skyline at dusk
float hash(float n) {
    return fract(sin(n * 127.1) * 43758.5);
}

void main() {
    // Sky gradient (dusk)
    vec3 sky_low = vec3(0.8, 0.4, 0.2);
    vec3 sky_high = vec3(0.1, 0.1, 0.3);
    vec3 sky = mix(sky_low, sky_high, uv.y);
    
    // Stars in upper sky
    float star = step(0.998, fract(sin(dot(floor(uv * 200.0), vec2(12.9, 78.2))) * 43758.5));
    sky += star * vec3(0.8) * smoothstep(0.6, 0.8, uv.y);
    
    vec3 col = sky;
    
    // Buildings: multiple layers
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float scale = 15.0 + fl * 10.0;
        float base_y = 0.2 + fl * 0.1;
        float height_scale = 0.15 + fl * 0.05;
        
        float bx = floor(uv.x * scale);
        float h = hash(bx + fl * 100.0);
        float building_h = base_y + h * height_scale;
        
        // Building shape
        float is_building = step(uv.y, building_h);
        
        // Windows
        vec2 wp = vec2(fract(uv.x * scale), uv.y);
        float win_x = step(0.15, fract(wp.x * 4.0)) * step(fract(wp.x * 4.0), 0.85);
        float win_y = step(0.2, fract(wp.y * 10.0)) * step(fract(wp.y * 10.0), 0.8);
        float lit = step(0.4, hash(bx * 7.0 + floor(wp.y * 10.0) + fl * 50.0));
        float window = win_x * win_y * lit;
        
        vec3 bldg_col = mix(vec3(0.05, 0.05, 0.08), vec3(0.1, 0.1, 0.15), fl * 0.3);
        vec3 win_col = vec3(0.9, 0.8, 0.4) * (0.5 + fl * 0.2);
        
        float mask = is_building * (1.0 - step(fl * 0.01, 0.0));
        col = mix(col, bldg_col, mask);
        col = mix(col, win_col, window * mask * is_building);
    }
    
    // Ground reflection
    float ground = step(uv.y, 0.15);
    col = mix(col, vec3(0.05, 0.05, 0.08), ground);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
