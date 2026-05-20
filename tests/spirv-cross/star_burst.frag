#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Stars and stripes abstract
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Radiating stripes
    float stripes = sin(a * 16.0) * 0.5 + 0.5;
    // Star points
    float star = 1.0;
    for (int i = 0; i < 8; i++) {
        float angle = float(i) * 0.785;
        vec2 dir = vec2(cos(angle), sin(angle));
        float proj = dot(uv, dir);
        star = min(star, proj);
    }
    star = smoothstep(0.3, 0.35, -star);
    vec3 col = vec3(0.1, 0.2, 0.5) * stripes;
    col += vec3(0.9, 0.8, 0.2) * star * (1.0 - step(0.4, r));
    col *= smoothstep(1.0, 0.5, r);
    fragColor = vec4(col, 1.0);
}
