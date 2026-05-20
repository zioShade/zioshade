#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Dragon curve fractal (simplified)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Iterative angle doubling
    float angle = a;
    float scale = 1.0;
    float val = 0.0;
    for (int i = 0; i < 10; i++) {
        val += sin(angle * float(1 << i)) * scale;
        scale *= 0.5;
    }
    val = val * 0.5 + 0.5;
    vec3 col = vec3(val, val * 0.7, val * 0.3) * smoothstep(1.2, 0.3, r);
    fragColor = vec4(col, 1.0);
}
