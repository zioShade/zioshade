#version 310 es
precision highp float;
out vec4 fragColor;

// Nested ternary with function calls and struct returns
struct Color {
    vec3 rgb;
    float alpha;
};

Color makeColor(float r, float g, float b) {
    Color c;
    c.rgb = vec3(r, g, b);
    c.alpha = 1.0;
    return c;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Color c = uv.x > 0.5
        ? (uv.y > 0.5 ? makeColor(1.0, 0.5, 0.0) : makeColor(0.0, 0.5, 1.0))
        : (uv.y > 0.5 ? makeColor(0.0, 1.0, 0.5) : makeColor(0.5, 0.0, 1.0));

    vec3 col = c.rgb;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
