#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float acc = 0.0;
    float prev = 1.0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float curr = sin(fi * 0.785 + uv.x * 3.0) * prev;
        acc += curr;
        prev = curr * 0.8 + 0.2;
    }
    vec3 col = vec3(acc * 0.1);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
