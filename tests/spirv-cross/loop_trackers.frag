#version 310 es
precision highp float;
out vec4 fragColor;

// Complex loop with break, continue, and multiple trackers
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float sum = 0.0;
    float product = 1.0;
    int count = 0;
    float maxVal = 0.0;

    for (int i = 0; i < 20; i++) {
        float fi = float(i);
        float val = fract(sin(fi * 12.9898 + uv.x * 78.233) * 43758.5453);

        if (val < 0.1) continue;  // skip low values
        if (sum > 5.0) break;     // stop accumulating

        sum += val;
        product *= val;
        count++;
        if (val > maxVal) maxVal = val;
    }

    float avg = sum / max(float(count), 1.0);
    vec3 col = vec3(avg, fract(product), maxVal * 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
