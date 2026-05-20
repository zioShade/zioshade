#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Wrought iron gate with scrollwork
    vec3 col = vec3(0.7, 0.65, 0.55); // wall
    // Gate frame
    float frame_left = smoothstep(0.04, 0.02, abs(uv.x - 2.0));
    float frame_right = smoothstep(0.04, 0.02, abs(uv.x - 8.0));
    float frame_top = smoothstep(0.04, 0.02, abs(uv.y - 9.0));
    float frame = max(max(frame_left, frame_right), frame_top) * step(2.0, uv.x) * step(uv.x, 8.0) * step(uv.y, 9.0);
    // Vertical bars
    float bars = 0.0;
    for (int i = 0; i < 6; i++) {
        float x = 3.0 + float(i) * 1.0;
        bars += smoothstep(0.03, 0.02, abs(uv.x - x));
    }
    bars = min(bars, 1.0) * step(0.0, uv.y) * step(uv.y, 9.0);
    // Scrollwork (circles at top)
    float scroll = 0.0;
    for (int i = 0; i < 5; i++) {
        float cx = 3.5 + float(i) * 1.0;
        float d = length(uv - vec2(cx, 7.5));
        scroll += smoothstep(0.35, 0.33, d) * (1.0 - smoothstep(0.28, 0.26, d));
    }
    scroll = min(scroll, 1.0);
    float iron = max(max(frame, bars), scroll);
    vec3 metal = vec3(0.2, 0.2, 0.22);
    col = mix(col, metal, iron);
    fragColor = vec4(col, 1.0);
}
