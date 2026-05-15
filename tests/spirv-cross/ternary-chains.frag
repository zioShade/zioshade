#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test chained ternary with mixed bool/float
    float x = uv.x;
    float r = x < 0.33 ? 0.0 : (x < 0.66 ? 0.5 : 1.0);

    // Test ternary with vector result
    float y = uv.y;
    vec3 color = y > 0.5 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 0.0, 1.0);

    fragColor = vec4(r * color, 1.0);
}
