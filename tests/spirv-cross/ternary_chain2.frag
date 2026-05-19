#version 450

// Test ternary operator chains and nested ternaries
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float a = (x < 0.33) ? 0.2 : (x < 0.66) ? 0.5 : 0.8;
    float b = (uv.y > 0.5) ? (x > 0.5 ? 1.0 : 0.5) : 0.0;
    float c = (x > 0.5 && uv.y > 0.5) ? 0.9 : ((x > 0.5 || uv.y > 0.5) ? 0.5 : 0.1);
    gl_FragColor = vec4(a, b, c, 1.0);
}
