#version 430
layout(location = 0) out vec4 FragColor;

// Test pow, sqrt, inversesqrt, exp2, log2
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    float x = uv.x;
    float y = uv.y;
    float r = pow(x, 2.0);
    float g = sqrt(y);
    float b = inversesqrt(x + 0.1) * 0.3;
    float a = exp2(x) * log2(y + 1.0) * 0.1;
    FragColor = vec4(r, g, b, a);
}
