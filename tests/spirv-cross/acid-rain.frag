#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test acid rain drip pattern
void main() {
    vec2 p = uv * vec2(8.0, 12.0);
    
    float col_id = floor(p.x);
    vec2 fp = fract(p);
    
    // Random drip offset
    float h = fract(sin(col_id * 127.1) * 43758.5);
    float speed = 0.5 + h * 1.5;
    
    // Drip position
    float drip_y = fract(fp.y + uv.x * speed);
    
    // Drip shape (teardrop)
    float width = 0.1 * (1.0 + drip_y * 0.5);
    float drip = smoothstep(width, width * 0.5, abs(fp.x - 0.5));
    drip *= step(0.3, drip_y);
    
    // Splash at bottom
    float splash_y = fract(p.y + uv.x * speed) - 0.95;
    float splash = smoothstep(0.05, 0.0, abs(splash_y)) * smoothstep(0.5, 0.3, abs(fp.x - 0.5));
    
    vec3 bg = vec3(0.05, 0.08, 0.05);
    vec3 rain = vec3(0.3, 1.0, 0.2);
    
    vec3 col = bg + (drip + splash * 0.5) * rain;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
