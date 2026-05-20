#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Butterfly wings
    uv.x = abs(uv.x); // bilateral symmetry
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Wing shape
    float wing_r = 0.6 + 0.2 * sin(a * 3.0) * cos(a * 2.0);
    float wing = smoothstep(wing_r + 0.01, wing_r - 0.01, r) * step(0.0, uv.y);
    // Pattern on wings
    float pattern = sin(a * 10.0 + r * 15.0) * 0.5 + 0.5;
    vec3 base = vec3(0.2, 0.1, 0.4);
    vec3 spots = vec3(0.9, 0.5, 0.1);
    vec3 col = mix(base, spots, pattern) * wing;
    // Body
    float body = smoothstep(0.03, 0.01, abs(uv.x)) * step(-0.3, uv.y) * step(uv.y, 0.5);
    col += vec3(0.1) * body;
    fragColor = vec4(col, 1.0);
}
