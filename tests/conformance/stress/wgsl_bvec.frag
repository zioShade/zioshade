// Test: boolean vector operations
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    bvec2 test = greaterThan(uv, vec2(0.5));
    bvec2 test2 = lessThan(uv, vec2(0.3));
    bvec2 combined = bvec2(test.x && test2.x, test.y || test2.y);
    
    float r = test.x ? 1.0 : 0.0;
    float g = test.y ? 1.0 : 0.0;
    float b = any(test) ? 0.5 : 0.0;
    float a = all(test2) ? 1.0 : 0.3;
    
    fragColor = vec4(r, g, b, a);
}
