// Test: ternary chains and nested expressions
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    float a = uv.x > 0.5 ? 1.0 : 0.0;
    float b = uv.y > 0.5 ? 2.0 : -1.0;
    float c = (a + b) > 1.5 ? 0.8 : 0.2;
    
    float nested = a > 0.0 ? (b > 0.0 ? c : 0.5) : (b > 0.0 ? 0.3 : 0.7);
    
    vec3 color = nested > 0.5 
        ? vec3(0.9, 0.4, 0.1) 
        : vec3(0.1, 0.4, 0.9);
    
    float chain = uv.x < 0.25 ? 0.0 : (uv.x < 0.5 ? 0.33 : (uv.x < 0.75 ? 0.66 : 1.0));
    
    fragColor = vec4(color * chain, 1.0);
}
