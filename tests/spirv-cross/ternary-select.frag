#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test ternary operator chains
void main() {
    float x = uv.x;
    float y = uv.y;
    
    // Nested ternaries for color selection
    float quadrant = (x > 0.5 ? 1.0 : 0.0) + (y > 0.5 ? 2.0 : 0.0);
    
    vec3 col;
    col = quadrant < 0.5 ? vec3(1.0, 0.0, 0.0) :
          quadrant < 1.5 ? vec3(0.0, 1.0, 0.0) :
          quadrant < 2.5 ? vec3(0.0, 0.0, 1.0) :
          vec3(1.0, 1.0, 0.0);
    
    // Gradient within quadrant
    float gradient = mod(x * 10.0, 1.0) * mod(y * 10.0, 1.0);
    col *= 0.5 + gradient * 0.5;
    
    fragColor = vec4(col, 1.0);
}
