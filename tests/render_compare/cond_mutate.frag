#version 430
layout(location = 0) out vec4 FragColor;

// Test conditional variable mutation
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0, 128.0);
    float x = uv.x;
    float y = uv.y;
    if (x > 0.5) {
        x += 0.1;
    } else {
        x -= 0.1;
    }
    if (y > 0.5) {
        y *= 2.0;
        y = clamp(y, 0.0, 1.0);
    }
    FragColor = vec4(x, y, (x + y) * 0.5, 1.0);
}
