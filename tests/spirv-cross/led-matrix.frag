#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test LED matrix / dot display
void main() {
    vec2 p = uv * vec2(32.0, 16.0);
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // LED dot shape: circle in center of cell
    vec2 center = vec2(0.5);
    float d = length(fp - center);
    float led_shape = smoothstep(0.4, 0.35, d);
    
    // Generate a pattern to display
    float h = fract(sin(dot(id, vec2(12.9, 78.2))) * 43758.5);
    
    // Checkerboard pattern with some variation
    float checker = mod(id.x + id.y, 2.0);
    float pattern = mix(checker, h, 0.3);
    
    // Scan line effect
    float scan = sin(uv.y * 200.0) * 0.1;
    
    // LED colors: green monochrome like old displays
    vec3 led_on = vec3(0.1, 0.8, 0.15);
    vec3 led_off = vec3(0.02, 0.06, 0.02);
    vec3 bg = vec3(0.03, 0.05, 0.03);
    
    float brightness = pattern * led_shape;
    vec3 col = mix(led_off, led_on, brightness);
    col += scan * col;
    
    // Pixel gap between LEDs
    float gap = step(0.9, fp.x) + step(0.9, fp.y);
    col = mix(col, bg, step(0.5, gap));
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
