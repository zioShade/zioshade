#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Do-while with early exit
    float r = length(uv);
    float sum = 0.0;
    int i = 0;
    do {
        float fi = float(i);
        sum += sin(r * float(i + 1) * 10.0) / float(i + 1);
        i++;
    } while (i < 5 && abs(sum) < 2.0);
    vec3 col = vec3(sum * 0.3 + 0.5);
    col *= smoothstep(1.0, 0.3, r);
    fragColor = vec4(col, 1.0);
}
