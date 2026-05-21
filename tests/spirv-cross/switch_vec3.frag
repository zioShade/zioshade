#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    int sector = int(floor(uv.x * 4.0 + 2.0));
    vec3 col;
    switch (sector) {
        case 0: col = vec3(0.8, 0.2, 0.1); break;
        case 1: col = vec3(0.1, 0.8, 0.3); break;
        case 2: col = vec3(0.2, 0.1, 0.8); break;
        case 3: col = vec3(0.8, 0.7, 0.1); break;
        default: col = vec3(0.5); break;
    }
    col *= 0.7 + 0.3 * sin(uv.y * 10.0);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
