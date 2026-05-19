#version 450

// Test: exp, log, exp2, log2 chain
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;

    float a = exp(x * 2.0 - 1.0);
    float b = log(max(x, 0.001));
    float c = exp2(y * 3.0);
    float d = log2(max(y, 0.001) + 1.0);

    float r = a / (1.0 + a);  // sigmoid
    float g = clamp(b * 0.5 + 0.5, 0.0, 1.0);
    float bl = d / 3.0;

    gl_FragColor = vec4(r, g, bl, 1.0);
}
