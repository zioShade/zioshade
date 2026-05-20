#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    // Chromatic aberration
    float angle = atan(uv.y, uv.x);
    float aberration = 0.02 * r;
    float r_ch = sin(angle * 3.0 - r * 10.0 + aberration * 10.0) * 0.5 + 0.5;
    float g_ch = sin(angle * 3.0 - r * 10.0) * 0.5 + 0.5;
    float b_ch = sin(angle * 3.0 - r * 10.0 - aberration * 10.0) * 0.5 + 0.5;
    vec3 col = vec3(r_ch, g_ch, b_ch);
    col *= smoothstep(1.0, 0.5, r);
    fragColor = vec4(col, 1.0);
}
