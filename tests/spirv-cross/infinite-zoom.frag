#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Shader toy-style infinite zoom (Droste effect)
void main() {
    vec2 p = uv * 2.0 - 1.0;
    
    // Convert to polar
    float r = length(p);
    float angle = atan(p.y, p.x);
    
    // Log-polar mapping for infinite zoom
    float zoom_r = log(r + 0.001);
    float zoom_angle = angle;
    
    // Wrap coordinates
    vec2 zoom_uv = vec2(zoom_r, zoom_angle / 6.28);
    zoom_uv = fract(zoom_uv);
    
    // Pattern in zoom space
    float pattern = step(0.5, fract(zoom_uv.x * 4.0)) * step(0.5, fract(zoom_uv.y * 4.0));
    
    vec3 col = mix(vec3(0.1, 0.0, 0.2), vec3(0.9, 0.5, 0.1), pattern);
    col *= smoothstep(0.0, 0.3, r);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
