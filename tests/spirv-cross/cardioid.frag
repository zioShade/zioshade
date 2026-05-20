#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Cardioid (heart-shaped curve)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Cardioid equation: r = a(1 + cos(theta))
    float cardioid_r = 0.4 * (1.0 + cos(a));
    float d = abs(r - cardioid_r);
    float curve = smoothstep(0.02, 0.01, d);
    float fill = smoothstep(0.02, 0.0, r - cardioid_r);
    vec3 col = vec3(0.05) + vec3(0.8, 0.2, 0.3) * fill * 0.3 + vec3(1.0, 0.4, 0.5) * curve;
    fragColor = vec4(col, 1.0);
}
