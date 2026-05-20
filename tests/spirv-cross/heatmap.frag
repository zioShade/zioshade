#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Heatmap / thermal camera view
    float val = sin(uv.x * 2.0) * cos(uv.y * 3.0) * 0.5 + 0.5;
    val += 0.2 * sin(uv.x * 5.0 - uv.y * 4.0);
    val = clamp(val, 0.0, 1.0);
    // Thermal color mapping: black -> blue -> red -> yellow -> white
    vec3 col;
    if (val < 0.25) {
        col = mix(vec3(0.0), vec3(0.0, 0.0, 0.5), val / 0.25);
    } else if (val < 0.5) {
        col = mix(vec3(0.0, 0.0, 0.5), vec3(0.8, 0.0, 0.0), (val - 0.25) / 0.25);
    } else if (val < 0.75) {
        col = mix(vec3(0.8, 0.0, 0.0), vec3(1.0, 1.0, 0.0), (val - 0.5) / 0.25);
    } else {
        col = mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 1.0, 1.0), (val - 0.75) / 0.25);
    }
    fragColor = vec4(col, 1.0);
}
