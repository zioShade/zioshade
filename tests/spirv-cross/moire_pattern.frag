#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Moire pattern from overlapping grids
    float g1 = sin(uv.x * 30.0) * sin(uv.y * 30.0);
    float g2 = sin((uv.x * 0.7 + uv.y * 0.7) * 30.0) * sin((uv.x * 0.7 - uv.y * 0.7) * 30.0);
    float moire = g1 + g2;
    vec3 col = vec3(moire * 0.25 + 0.5);
    fragColor = vec4(col, 1.0);
}
