#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Sonic boom / shock wave
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float shock = sin(r * 30.0 - 3.0) * exp(-r * 2.0);
    float mach_cone = smoothstep(0.02, 0.0, abs(a - 0.5)) * step(0.2, r);
    mach_cone += smoothstep(0.02, 0.0, abs(a + 0.5)) * step(0.2, r);
    vec3 col = vec3(0.05, 0.05, 0.1);
    col += vec3(0.4, 0.5, 0.8) * max(shock, 0.0);
    col += vec3(0.8, 0.3, 0.1) * mach_cone;
    fragColor = vec4(col, 1.0);
}
