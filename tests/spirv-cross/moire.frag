#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Moire pattern from overlapping grids
    float g1 = sin(uv.x * 80.0) * sin(uv.y * 80.0);
    float g2 = sin((uv.x - 0.01) * 80.0) * sin((uv.y - 0.01) * 80.0);
    float moire = (g1 + g2) * 0.25 + 0.5;
    float r = length(uv);
    vec3 col = vec3(moire) * vec3(0.3, 0.4, 0.8) * smoothstep(1.2, 0.5, r);
    fragColor = vec4(col, 1.0);
}
