#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy;
    float x = 0.0;
    // Complex loop condition with multiple variables
    for (int i = 0; i < 20 && x < 10.0; i++) {
        float y = float(i) * 0.1;
        x += sin(uv.x * y) * cos(uv.y * y);
        if (x > 5.0 && i > 5) break;
    }
    fragColor = vec4(x * 0.1);
}
