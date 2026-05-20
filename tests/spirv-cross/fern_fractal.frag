#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Barnsley fern (IFS approximation via spirals)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Multiple rotated copies suggest fern fronds
    float frond = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float offset = fi * 1.2566;
        float frond_a = a - offset;
        float frond_r = r * (1.0 + 0.3 * sin(frond_a * 8.0));
        frond += smoothstep(0.02, 0.0, abs(frond_r - 0.3));
    }
    vec3 col = vec3(0.05, 0.15, 0.05) + vec3(0.1, 0.4, 0.1) * frond;
    fragColor = vec4(col, 1.0);
}
