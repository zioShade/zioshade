#version 310 es
precision highp float;
out vec4 fragColor;

// Ternary chain feeding into another ternary, used in array index
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float a = uv.x > 0.5 ? 0.2 : 0.8;
    float b = uv.y > 0.5 ? 0.3 : 0.7;
    float c = a > b ? a + 0.1 : b + 0.2;
    int idx = int(c * 4.0);
    idx = clamp(idx, 0, 3);

    float vals[4];
    vals[0] = 0.1;
    vals[1] = 0.4;
    vals[2] = 0.7;
    vals[3] = 0.9;

    float val = vals[idx] + a * 0.5 + b * 0.3;
    vec3 col = vec3(val, fract(val * 2.0), c);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
