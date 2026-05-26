// Test: multiple nested conditionals with variable shadowing
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    float val = 0.0;
    
    if (uv.x > 0.5) {
        float weight = uv.x * 2.0;
        if (uv.y > 0.5) {
            val = weight * 0.8;
        } else {
            val = weight * 0.4;
        }
    } else {
        float weight = uv.y * 3.0;
        if (weight > 1.0) {
            val = weight - 1.0;
        } else {
            val = weight * 0.5;
        }
    }
    
    fragColor = vec4(vec3(val), 1.0);
}
