#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Test ! on float/int values
    float a = step(0.0, uv.x); // 0.0 or 1.0
    float b = step(0.0, uv.y); // 0.0 or 1.0
    // !float should convert to bool first
    float na = float(!a);
    float nb = float(!b);
    // Combine
    vec3 col = vec3(na, nb, a * b);
    fragColor = vec4(col, 1.0);
}
