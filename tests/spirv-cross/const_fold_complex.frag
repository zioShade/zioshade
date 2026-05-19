#version 450

// Test constant folding with complex expressions
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    const float pi = 3.14159265;
    const float half_pi = pi / 2.0;
    const float two_pi = pi * 2.0;
    const float inv_pi = 1.0 / pi;

    float a = sin(uv.x * two_pi) * 0.5 + 0.5;
    float b = cos(uv.y * half_pi) * 0.5 + 0.5;
    float c = sin(uv.x * pi + uv.y * half_pi) * inv_pi;

    gl_FragColor = vec4(a, b, c * 0.5 + 0.5, 1.0);
}
