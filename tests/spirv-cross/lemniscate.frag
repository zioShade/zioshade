#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Butterfly curve (parametric, polar)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Lemniscate of Bernoulli (figure-8)
    float cos2a = cos(2.0 * a);
    float lem_r = 0.4 * sqrt(abs(cos2a));
    float d = abs(r - lem_r);
    float curve = smoothstep(0.015, 0.005, d);
    float fill = smoothstep(0.015, 0.0, r - lem_r) * step(0.0, cos2a);
    vec3 col = vec3(0.02);
    col += vec3(0.7, 0.3, 0.8) * fill * 0.3;
    col += vec3(0.9, 0.5, 1.0) * curve;
    fragColor = vec4(col, 1.0);
}
