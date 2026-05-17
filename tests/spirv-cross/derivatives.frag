#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

// Test dFdx and dFdy (fragment shader derivatives)
void main() {
    // Compute some function and its derivatives
    float f = sin(uv.x * 10.0) * cos(uv.y * 10.0);
    float dfdx = dFdx(f);
    float dfdy = dFdy(f);
    
    // Gradient magnitude
    float grad = length(vec2(dfdx, dfdy));
    
    vec3 col = vec3(f * 0.5 + 0.5, grad * 2.0, abs(dfdx) * 5.0);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
