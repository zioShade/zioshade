#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test Penrose-style impossible staircase
void main() {
    vec2 p = uv * 6.0;
    
    // Staircase steps that go in circles
    float step_x = floor(p.x);
    float step_y = floor(p.y);
    vec2 fp = fract(p);
    
    // Each step is higher on the right
    float height = mod(step_x + step_y, 4.0);
    float step_surface = 1.0 - step(fp.x, 0.6);
    
    // Top face of step
    float top = step(0.1, fp.x) * step(fp.x, 0.6) * step(0.1, fp.y) * step(fp.y, 0.6 + height * 0.05);
    
    // Front face of step
    float front = step(0.1, fp.x) * step(fp.x, 0.6) * step(0.6 + height * 0.05 - 0.02, fp.y) * step(fp.y, 0.6 + height * 0.05);
    
    // Color by height
    float t = height / 4.0;
    vec3 step_col = mix(vec3(0.3, 0.4, 0.6), vec3(0.8, 0.6, 0.3), t);
    vec3 front_col = step_col * 0.7;
    
    vec3 col = vec3(0.95);
    col = mix(col, step_col, top);
    col = mix(col, front_col, front);
    
    fragColor = vec4(col, 1.0);
}
