#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test shadow comparison with smoothstep
void main() {
    vec2 light = vec2(0.5, 0.8);
    vec2 occluder = vec2(0.5, 0.4);
    float occluder_r = 0.15;
    
    vec2 to_light = light - uv;
    vec2 to_occluder = occluder - uv;
    
    float angle_to_light = atan(to_light.y, to_light.x);
    float angle_to_occ = atan(to_occluder.y, to_occluder.x);
    
    float d_occ = length(to_occluder);
    float d_light = length(to_light);
    
    // Soft shadow approximation
    float shadow = 0.0;
    if (d_occ < d_light) {
        float ang_diff = abs(angle_to_light - angle_to_occ);
        ang_diff = min(ang_diff, 6.28318 - ang_diff);
        float penumbra = occluder_r / d_occ;
        shadow = smoothstep(penumbra, penumbra * 0.5, ang_diff);
    }
    
    float light_att = 1.0 / (1.0 + d_light * 3.0);
    float lit = light_att * (1.0 - shadow);
    
    vec3 col = vec3(0.05) + vec3(1.0, 0.9, 0.7) * lit;
    
    // Draw occluder
    float d = length(uv - occluder);
    col = mix(col, vec3(0.3), smoothstep(0.15, 0.14, d));
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
