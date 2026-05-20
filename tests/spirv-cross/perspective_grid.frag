#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Perspective grid
    float fov = 1.0;
    float z = fov / (uv.y + 0.5);
    float x = uv.x * z;
    // Grid lines
    float grid_x = abs(fract(x * 3.0) - 0.5);
    float grid_z = abs(fract(z * 2.0) - 0.5);
    float line_x = smoothstep(0.05, 0.02, grid_x);
    float line_z = smoothstep(0.05, 0.02, grid_z);
    float grid = max(line_x, line_z);
    // Fade with distance
    float fade = exp(-uv.y * 2.0);
    vec3 col = vec3(0.0, grid * fade, grid * fade * 0.5);
    // Horizon
    col += vec3(0.05, 0.02, 0.08) * smoothstep(0.0, -0.3, uv.y);
    fragColor = vec4(col, 1.0);
}
