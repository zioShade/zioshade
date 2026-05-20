#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Fourier series square wave approximation
    float x = uv.x * 6.28 * 2.0;
    float sum = 0.0;
    for (int n = 0; n < 7; n++) {
        float k = float(n * 2 + 1);
        sum += sin(k * x) / k;
    }
    sum *= 4.0 / 3.14159;
    float d = abs(uv.y - sum * 0.3);
    float line = smoothstep(0.02, 0.005, d);
    vec3 col = vec3(0.05) + vec3(0.3, 0.6, 1.0) * line;
    // Ideal square wave overlay
    float sq = step(0.0, sin(x)) * 0.3;
    float d2 = abs(uv.y - sq);
    col += vec3(0.8, 0.3, 0.1) * smoothstep(0.02, 0.005, d2) * 0.5;
    fragColor = vec4(col, 1.0);
}
