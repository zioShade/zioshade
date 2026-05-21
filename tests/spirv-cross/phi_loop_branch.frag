#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float sum = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float d = abs(r - fi * 0.15);
        float val;
        if (d < 0.05) { val = 1.0; }
        else { val = 0.1 / (d + 0.01); }
        sum += val;
    }
    vec3 col = vec3(sum * 0.15);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
