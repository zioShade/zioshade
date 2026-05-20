#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Fingerprint pattern
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Concentric ridges with angular variation
    float ridge = sin(r * 50.0 + sin(a * 3.0) * 5.0) * 0.5 + 0.5;
    float fade = smoothstep(0.9, 0.6, r) * smoothstep(0.0, 0.1, r);
    // Core whorl
    float core = smoothstep(0.1, 0.05, r);
    vec3 col = vec3(0.1);
    col += vec3(0.6, 0.4, 0.3) * ridge * fade;
    col += vec3(0.4, 0.25, 0.2) * core;
    fragColor = vec4(col, 1.0);
}
