#version 310 es
precision highp float;
out vec4 fragColor;

// Mixed int/float operations with conversions
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    int a = int(uv.x * 10.0);
    int b = int(uv.y * 10.0);
    int sum = a + b;
    int diff = a - b;
    int prod = a * (b + 1);
    float ratio = float(sum) / max(float(prod), 1.0);

    uint ua = uint(a + 10);
    uint ub = uint(b + 10);
    uint umask = ua & ub | (ua ^ ub);
    float uval = float(int(umask % 100u)) / 100.0;

    vec3 col = vec3(ratio, uval, float(diff + 50) * 0.01);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
