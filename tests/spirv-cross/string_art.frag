#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // String art / geometric lines
    float r = length(uv);
    vec3 col = vec3(0.05);
    // Lines from N equally-spaced points on left to right
    int n = 12;
    for (int i = 0; i < n; i++) {
        float fi = float(i);
        float y_top = -0.8 + fi * 1.6 / float(n);
        float y_bot = 0.8 - fi * 1.6 / float(n);
        // Distance from line segment
        vec2 pa = uv - vec2(-0.8, y_top);
        vec2 ba = vec2(1.6, y_bot - y_top);
        float t = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float d = length(pa - ba * t);
        float line = smoothstep(0.005, 0.002, d);
        float hue = fi / float(n);
        vec3 line_col = vec3(
            sin(hue * 6.28) * 0.5 + 0.5,
            sin(hue * 6.28 + 2.09) * 0.5 + 0.5,
            sin(hue * 6.28 + 4.18) * 0.5 + 0.5
        );
        col += line_col * line;
    }
    fragColor = vec4(col, 1.0);
}
