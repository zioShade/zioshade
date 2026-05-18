#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Mayan step pyramid pattern
void main() {
    vec2 p = uv * 10.0;
    vec2 id = floor(p);
    vec2 fp = fract(p);
    
    // Stepped pyramid: each level is smaller
    float cx = 5.0;
    float cy = 5.0;
    float dx = abs(id.x - cx);
    float dy = abs(id.y - cy);
    float level = max(dx, dy);
    
    // Height based on level (lower = higher)
    float height = (5.0 - level) * 0.15;
    
    // Top face
    float top = step(height, fp.y);
    
    // Front face (visible on bottom edge of each step)
    float front = 1.0 - top;
    
    // Stone texture per block
    float h = fract(sin(dot(id, vec2(127.1, 311.7))) * 43758.5);
    float stone = step(0.1, fp.x) * step(fp.x, 0.9) * step(0.1, fp.y) * step(fp.y, 0.9);
    
    // Only draw within pyramid bounds
    float in_pyramid = step(level, 4.5);
    
    float t = level / 5.0;
    vec3 top_col = mix(vec3(0.6, 0.5, 0.3), vec3(0.4, 0.35, 0.2), t) * (0.8 + h * 0.2);
    vec3 front_col = top_col * 0.65;
    
    vec3 col = vec3(0.6, 0.8, 0.95); // sky
    col = mix(col, top_col * stone, in_pyramid * top);
    col = mix(col, front_col * stone, in_pyramid * front);
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
