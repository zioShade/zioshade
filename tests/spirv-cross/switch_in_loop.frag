#version 310 es
precision highp float;
out vec4 fragColor;

// Switch inside loop with variable used after both switch and loop
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float accum = 0.0;
    for (int i = 0; i < 5; i++) {
        float val = fract(sin(float(i) * 127.1 + uv.x * 311.7) * 43758.5);

        int mode = i % 3;
        float result;
        switch (mode) {
            case 0: result = val * 2.0; break;
            case 1: result = val + 0.5; break;
            default: result = val * val; break;
        }

        if (result > 0.8) {
            accum += result;
        } else {
            accum += result * 0.5;
        }
    }

    vec3 col = vec3(fract(accum), fract(accum * 0.7), fract(accum * 0.3));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
