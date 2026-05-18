#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test coral reef organic pattern
void main() {
    vec2 p = uv * 8.0;
    vec2 id = floor(p);
    vec2 fp = fract(p) - 0.5;
    
    float h1 = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    float h2 = fract(sin(dot(id, vec2(269.5, 183.3))) * 43758.5);
    
    // Branching coral shape: multiple arms from center
    float arms = 0.0;
    float num_arms = 3.0 + floor(h1 * 4.0);
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        if (fi >= num_arms) break;
        float arm_angle = fi * 6.28318 / num_arms + h2 * 3.14;
        vec2 dir = vec2(cos(arm_angle), sin(arm_angle));
        float proj = dot(fp, dir);
        float perp = abs(dot(fp, vec2(-dir.y, dir.x)));
        float arm = smoothstep(0.06, 0.02, perp) * step(0.0, proj) * smoothstep(0.4, 0.35, proj);
        arms = max(arms, arm);
    }
    
    // Polyp dots at tips
    float polyp = smoothstep(0.08, 0.03, length(fp) - 0.3) * step(0.25, length(fp));
    
    vec3 coral_col = mix(vec3(0.9, 0.4, 0.3), vec3(1.0, 0.7, 0.2), h1);
    vec3 polyp_col = vec3(1.0, 0.9, 0.6);
    
    vec3 col = vec3(0.05, 0.15, 0.25);
    col += arms * coral_col;
    col += polyp * polyp_col;
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
