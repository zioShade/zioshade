#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test all comparison operators
void main() {
    float a = uv.x;
    float b = uv.y;
    
    float lt = a < b ? 1.0 : 0.0;
    float le = a <= b ? 1.0 : 0.0;
    float gt = a > b ? 1.0 : 0.0;
    float ge = a >= b ? 1.0 : 0.0;
    float eq = abs(a - b) < 0.01 ? 1.0 : 0.0;
    float ne = abs(a - b) >= 0.01 ? 1.0 : 0.0;
    
    vec3 col = vec3(lt + le, gt + ge, eq + ne) * 0.25;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
