#version 450

// Test: many sequential operations
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;

    x = x * 2.0;
    x = x - 1.0;
    x = abs(x);
    x = sqrt(x);
    x = x * x;
    x = 1.0 - x;
    x = clamp(x, 0.0, 1.0);
    x = smoothstep(0.0, 1.0, x);
    x = pow(x, 0.5);

    gl_FragColor = vec4(x, uv.y, 1.0 - x, 1.0);
}
