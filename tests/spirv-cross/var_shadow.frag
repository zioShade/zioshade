#version 450
layout(location = 0) out vec4 FragColor;

// Test: variable shadowing in function scope
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float val = uv.x;
    {
        float val = uv.y;
        FragColor = vec4(val, 0.0, 0.0, 1.0);
    }
}
