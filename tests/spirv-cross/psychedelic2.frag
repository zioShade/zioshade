#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Psychedelic swirl v2
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float twist = a + r * 5.0 + sin(r * 10.0) * 2.0;
    vec3 col = vec3(
        sin(twist) * 0.5 + 0.5,
        sin(twist + 2.09) * 0.5 + 0.5,
        sin(twist + 4.18) * 0.5 + 0.5
    );
    col *= smoothstep(1.0, 0.8, r);
    fragColor = vec4(col, 1.0);
}
