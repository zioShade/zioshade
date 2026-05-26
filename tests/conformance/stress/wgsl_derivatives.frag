// Test: derivative functions
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float v = sin(uv.x * 10.0) * cos(uv.y * 8.0);
    
    float dx = dFdx(v);
    float dy = dFdy(v);
    float fw = fwidth(v);
    
    vec3 color = vec3(abs(dx) * 5.0, abs(dy) * 5.0, fw * 5.0);
    fragColor = vec4(color, 1.0);
}
