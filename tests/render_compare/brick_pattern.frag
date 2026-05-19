#version 430
layout(location = 0) out vec4 FragColor;

// Test: procedural brick pattern
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 4.0;

    float row = floor(uv.y);
    float offset = mod(row, 2.0) * 0.5;
    vec2 brick = vec2(fract(uv.x + offset), fract(uv.y));

    float mortar = step(0.95, brick.x) + step(0.95, brick.y);
    mortar = clamp(mortar, 0.0, 1.0);

    vec3 brickCol = vec3(0.7, 0.3, 0.2);
    vec3 mortarCol = vec3(0.8, 0.75, 0.7);
    vec3 col = mix(brickCol, mortarCol, mortar);

    FragColor = vec4(col, 1.0);
}
