#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Greek meander pattern
    float scale = 3.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float h = mod(cell.x + cell.y, 4.0);
    // Meander step shape
    float step_shape = 0.0;
    if (h < 1.0) {
        step_shape = max(
            smoothstep(0.3, 0.28, max(abs(f.x - 0.5), abs(f.y - 0.75))) * step(f.y, 0.75),
            smoothstep(0.3, 0.28, max(abs(f.x - 0.25), abs(f.y - 0.5))) * step(f.x, 0.25)
        );
    } else if (h < 2.0) {
        step_shape = max(
            smoothstep(0.3, 0.28, max(abs(f.x - 0.5), abs(f.y - 0.25))) * step(0.25, f.y),
            smoothstep(0.3, 0.28, max(abs(f.x - 0.75), abs(f.y - 0.5))) * step(0.75, f.x)
        );
    } else if (h < 3.0) {
        step_shape = smoothstep(0.3, 0.28, max(abs(f.x - 0.5), abs(f.y - 0.5)));
    } else {
        step_shape = smoothstep(0.15, 0.13, max(abs(f.x - 0.5), abs(f.y - 0.5)));
    }
    vec3 bg = vec3(0.95, 0.92, 0.85);
    vec3 pattern = vec3(0.15, 0.2, 0.5);
    vec3 col = mix(bg, pattern, step_shape);
    fragColor = vec4(col, 1.0);
}
