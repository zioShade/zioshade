#version 310 es
precision highp float;
out vec4 fragColor;

// Test: switch with complex expressions and default
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    int sector = int(floor(atan(uv.y, uv.x) * 3.0 / 3.14159)) + 3;
    sector = clamp(sector, 0, 5);
    vec3 col;
    switch (sector) {
        case 0: col = vec3(0.8, 0.2, 0.2); break;
        case 1: col = vec3(0.8, 0.7, 0.1); break;
        case 2: col = vec3(0.2, 0.8, 0.2); break;
        case 3: col = vec3(0.1, 0.5, 0.8); break;
        case 4: col = vec3(0.5, 0.2, 0.8); break;
        default: col = vec3(0.6, 0.6, 0.6); break;
    }
    float r = length(uv);
    col *= smoothstep(1.0, 0.3, r);
    fragColor = vec4(col, 1.0);
}
