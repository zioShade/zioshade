#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Acid trip / psychedelic pattern
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float p1 = sin(a * 8.0 + r * 10.0);
    float p2 = cos(a * 5.0 - r * 8.0);
    float p3 = sin(a * 3.0 + r * 15.0 + p1);
    float combined = (p1 + p2 + p3) * 0.25 + 0.5;
    vec3 col = vec3(
        sin(combined * 6.28 + 0.0) * 0.5 + 0.5,
        sin(combined * 6.28 + 2.09) * 0.5 + 0.5,
        sin(combined * 6.28 + 4.18) * 0.5 + 0.5
    );
    col *= smoothstep(1.2, 0.3, r);
    fragColor = vec4(col, 1.0);
}
