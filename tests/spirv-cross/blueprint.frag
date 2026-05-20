#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Blueprint / technical drawing
    vec3 bg = vec3(0.05, 0.1, 0.3);
    vec3 line_col = vec3(0.3, 0.6, 1.0);
    vec3 col = bg;
    // Grid
    float grid = smoothstep(0.02, 0.01, min(fract(uv.x), fract(uv.y)));
    float grid_major = smoothstep(0.02, 0.01, min(fract(uv.x * 0.2), fract(uv.y * 0.2)));
    col += line_col * grid * 0.3;
    col += line_col * grid_major * 0.5;
    // Circle
    float r = length(uv - vec2(3.0, 3.0));
    float circle = smoothstep(0.03, 0.01, abs(r - 1.5));
    col += line_col * circle;
    // Dimensions
    float dim_h = smoothstep(0.02, 0.0, abs(uv.y - 5.0)) * step(1.5, uv.x) * step(uv.x, 4.5);
    col += line_col * dim_h;
    fragColor = vec4(col, 1.0);
}
