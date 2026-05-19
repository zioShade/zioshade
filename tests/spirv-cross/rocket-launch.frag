#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test rocket launch with exhaust
void main() {
    // Night sky
    vec3 col = mix(vec3(0.0, 0.0, 0.05), vec3(0.02, 0.02, 0.1), uv.y);
    
    // Stars
    float star = step(0.997, fract(sin(dot(floor(uv * 300.0), vec2(12.9, 78.2))) * 43758.5));
    col += star * vec3(0.7, 0.75, 0.85);
    
    // Rocket body
    float rx = 0.5;
    float ry = 0.6;
    float rw = 0.025;
    float rh = 0.15;
    
    // Body (cylinder)
    float body = smoothstep(rw, rw - 0.003, abs(uv.x - rx)) * step(ry - rh, uv.y) * step(uv.y, ry + rh);
    col = mix(col, vec3(0.85, 0.85, 0.9), body);
    
    // Nose cone (triangle)
    float nose_base = ry + rh;
    float nose_top = nose_base + 0.06;
    float nose_w = (nose_top - uv.y) / (nose_top - nose_base) * rw;
    float nose = smoothstep(nose_w, nose_w - 0.002, abs(uv.x - rx)) * step(nose_base, uv.y) * step(uv.y, nose_top);
    col = mix(col, vec3(0.9, 0.2, 0.15), nose);
    
    // Fins
    float fin_l = smoothstep(0.04, 0.0, uv.x - (rx - rw)) * step(rx - rw - 0.04, uv.x) * step(ry - rh, uv.y) * step(uv.y, ry - rh + 0.04);
    float fin_r = smoothstep(0.04, 0.0, (rx + rw) - uv.x) * step(uv.x, rx + rw + 0.04) * step(ry - rh, uv.y) * step(uv.y, ry - rh + 0.04);
    col = mix(col, vec3(0.9, 0.2, 0.15), max(fin_l, fin_r));
    
    // Window
    float win_d = length(uv - vec2(rx, ry + 0.05));
    float window = smoothstep(0.015, 0.012, win_d);
    col = mix(col, vec3(0.3, 0.6, 0.9), window);
    
    // Exhaust flame
    vec2 ep = uv - vec2(rx, ry - rh);
    float flame_r = length(ep * vec2(1.0, 0.5));
    float flame_a = atan(ep.x, -ep.y);
    float flame_shape = smoothstep(0.15, 0.0, flame_r) * step(0.0, ep.y);
    
    // Inner core (white/yellow)
    float inner = smoothstep(0.05, 0.0, flame_r) * step(0.0, ep.y);
    vec3 flame_col = mix(vec3(1.0, 0.5, 0.1), vec3(1.0, 0.9, 0.3), flame_shape);
    col = mix(col, flame_col, flame_shape);
    col = mix(col, vec3(1.0, 1.0, 0.9), inner);
    
    // Glow
    float glow = exp(-length(uv - vec2(rx, ry - rh)) * 6.0) * 0.15;
    col += glow * vec3(1.0, 0.6, 0.2);
    
    // Exhaust smoke trail
    float smoke = exp(-abs(uv.x - rx) * 20.0) * step(0.0, ry - rh - uv.y) * 0.15;
    smoke *= smoothstep(0.0, 0.3, ry - rh - uv.y);
    col += smoke * vec3(0.5, 0.5, 0.55);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
