#version 450

// Test: compound assignment operators
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float x = uv.x;
    x += 0.1;
    x *= 2.0;
    x -= 0.3;
    x /= 3.0;

    float y = uv.y;
    y += y * 0.5;  // y = y * 1.5
    y *= 0.8;

    gl_FragColor = vec4(clamp(x, 0.0, 1.0), clamp(y, 0.0, 1.0), 0.5, 1.0);
}
