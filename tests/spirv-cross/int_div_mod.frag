#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Integer division and modulo for grid pattern
    int x = int(uv.x);
    int y = int(uv.y);
    int sum = x + y;
    int remainder = sum - (sum / 3) * 3;
    float f = float(remainder) / 2.0;
    vec3 col = vec3(f, 1.0 - f, abs(f - 0.5));
    fragColor = vec4(col, 1.0);
}
