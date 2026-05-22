// Tests: switch with struct return from each case
precision mediump float;
uniform vec2 u_resolution;

struct ColorResult {
    vec3 rgb;
    float alpha;
};

ColorResult getTheme(int theme) {
    ColorResult r;
    switch (theme) {
        case 0: r.rgb = vec3(0.8, 0.2, 0.1); r.alpha = 1.0; break;
        case 1: r.rgb = vec3(0.1, 0.8, 0.3); r.alpha = 0.9; break;
        case 2: r.rgb = vec3(0.2, 0.3, 0.9); r.alpha = 0.8; break;
        case 3: r.rgb = vec3(0.9, 0.8, 0.1); r.alpha = 0.7; break;
        default: r.rgb = vec3(0.5); r.alpha = 1.0; break;
    }
    return r;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    int theme = int(uv.x * 4.999);
    theme = clamp(theme, 0, 4);
    ColorResult c = getTheme(theme);
    gl_FragColor = vec4(c.rgb * uv.y, c.alpha);
}
