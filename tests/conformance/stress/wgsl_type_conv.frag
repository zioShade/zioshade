#version 450
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    // Type conversions
    int i = int(uv.x * 10.0);
    uint u = uint(uv.y * 10.0);
    float f1 = float(i) / 10.0;
    float f2 = float(u) / 10.0;
    fragColor = vec4(f1, f2, 0.0, 1.0);
}
