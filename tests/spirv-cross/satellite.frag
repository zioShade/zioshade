#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Parabolic antenna / satellite dish
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Parabolic curve y = x^2
    float parabola = uv.x * uv.x * 2.0;
    float d_parabola = abs(uv.y - parabola + 0.3);
    float dish_line = smoothstep(0.02, 0.01, d_parabola) * step(abs(uv.x), 0.7);
    // Feed horn at focal point
    float feed = smoothstep(0.03, 0.02, length(uv - vec2(0.0, 0.2)));
    // Support struts
    float strut1 = smoothstep(0.01, 0.005, abs(uv.y - uv.x * 0.3 - 0.15));
    float strut2 = smoothstep(0.01, 0.005, abs(uv.y + uv.x * 0.3 - 0.15));
    vec3 col = vec3(0.1);
    col += vec3(0.6, 0.6, 0.65) * dish_line;
    col += vec3(0.8, 0.2, 0.1) * feed;
    col += vec3(0.3) * min(strut1 + strut2, 1.0) * step(0.1, r);
    fragColor = vec4(col, 1.0);
}
