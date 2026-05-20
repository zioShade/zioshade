#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.008;
    // X-ray / blueprint of building
    vec3 col = vec3(0.0, 0.05, 0.15);
    vec3 wire = vec3(0.0, 0.6, 1.0);
    // Building outline
    float bx = smoothstep(0.02, 0.01, abs(uv.x - 3.0)) * step(1.0, uv.y) * step(uv.y, 8.0);
    float bx2 = smoothstep(0.02, 0.01, abs(uv.x - 7.0)) * step(1.0, uv.y) * step(uv.y, 6.0);
    float floor1 = smoothstep(0.02, 0.01, abs(uv.y - 3.0)) * step(3.0, uv.x) * step(uv.x, 7.0);
    float floor2 = smoothstep(0.02, 0.01, abs(uv.y - 5.0)) * step(3.0, uv.x) * step(uv.x, 7.0);
    float ground = smoothstep(0.02, 0.01, abs(uv.y - 1.0)) * step(1.0, uv.x) * step(uv.x, 9.0);
    // Windows
    float win = smoothstep(0.15, 0.13, max(abs(uv.x - 4.0), abs(uv.y - 4.0)));
    win += smoothstep(0.15, 0.13, max(abs(uv.x - 6.0), abs(uv.y - 4.0)));
    win += smoothstep(0.15, 0.13, max(abs(uv.x - 4.0), abs(uv.y - 6.0)));
    col += wire * (bx + bx2 + floor1 + floor2 + ground + win * 0.5);
    fragColor = vec4(col, 1.0);
}
