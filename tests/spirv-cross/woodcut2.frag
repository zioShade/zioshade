#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Woodcut relief print effect
    float angle = 0.7;
    float c = cos(angle);
    float s = sin(angle);
    vec2 rot = vec2(c * uv.x - s * uv.y, s * uv.x + c * uv.y);
    // Woodcut lines (closely spaced)
    float lines = sin(rot.y * 8.0) * 0.5 + 0.5;
    // Ink density based on scene
    float scene = sin(uv.x * 0.8) * cos(uv.y * 0.6) + 0.5;
    float ink = step(lines, scene);
    vec3 paper = vec3(0.92, 0.88, 0.82);
    vec3 ink_col = vec3(0.08, 0.06, 0.05);
    vec3 col = mix(paper, ink_col, ink);
    fragColor = vec4(col, 1.0);
}
