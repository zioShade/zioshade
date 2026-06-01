#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test weathervane / wind direction indicator
void main() {
    vec2 p = uv - vec2(0.5, 0.55);
    float r = length(p);
    float a = atan(p.y, p.x);
    
    // Sky gradient
    vec3 sky_low = vec3(0.7, 0.75, 0.85);
    vec3 sky_high = vec3(0.3, 0.5, 0.8);
    vec3 col = mix(sky_low, sky_high, uv.y);
    
    // Pole
    float pole = smoothstep(0.008, 0.003, abs(uv.x - 0.5)) * step(0.1, uv.y) * smoothstep(0.93, 0.91, uv.y);
    col = mix(col, vec3(0.4, 0.38, 0.35), pole);
    
    // Compass rose at top
    vec2 rose_center = vec2(0.5, 0.88);
    float rc = length(uv - rose_center);
    
    // N/S/E/W points
    float points = 0.0;
    for (int i = 0; i < 4; i++) {
        float pa = float(i) * 1.5708 - 1.5708;
        vec2 dir = vec2(cos(pa), sin(pa));
        float proj = dot(uv - rose_center, dir);
        float perp = abs(dot(uv - rose_center, vec2(-dir.y, dir.x)));
        float point = smoothstep(0.015, 0.005, perp) * step(0.0, proj) * smoothstep(0.08, 0.07, proj);
        points += point;
    }
    
    // Diagonal shorter points
    for (int i = 0; i < 4; i++) {
        float pa = float(i) * 1.5708 - 1.5708 + 0.7854;
        vec2 dir = vec2(cos(pa), sin(pa));
        float proj = dot(uv - rose_center, dir);
        float perp = abs(dot(uv - rose_center, vec2(-dir.y, dir.x)));
        float point = smoothstep(0.01, 0.004, perp) * step(0.0, proj) * smoothstep(0.05, 0.04, proj);
        points += point * 0.6;
    }
    
    // Center circle
    float center_dot = smoothstep(0.012, 0.008, rc);
    
    col += points * vec3(0.5, 0.45, 0.4);
    col += center_dot * vec3(0.6, 0.55, 0.5);
    
    // Rooster silhouette (simplified)
    vec2 rp = uv - vec2(0.48, 0.72);
    float body = smoothstep(0.035, 0.03, length(rp - vec2(0.0, 0.0)));
    float head = smoothstep(0.018, 0.015, length(rp - vec2(-0.01, 0.035)));
    float tail = smoothstep(0.005, 0.002, abs(rp.x - 0.03)) * step(0.0, rp.y) * smoothstep(0.05, 0.03, rp.y);
    float beak = smoothstep(0.004, 0.001, abs(rp.y - 0.045)) * step(-0.04, rp.x) * step(rp.x, -0.02);
    
    float rooster = max(max(body, head), max(tail, beak));
    col = mix(col, vec3(0.15), rooster);
    
    // Ground
    float ground = smoothstep(0.12, 0.1, uv.y);
    col = mix(col, vec3(0.3, 0.4, 0.2), ground);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
