#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Topographic contour lines
    float val = sin(uv.x * 2.0) * cos(uv.y * 3.0) + sin(uv.x * 0.7 - uv.y * 1.2);
    float contour = fract(val * 5.0);
    float line = abs(contour - 0.5);
    line = smoothstep(0.05, 0.02, line);
    vec3 low = vec3(0.2, 0.5, 0.3);
    vec3 high = vec3(0.8, 0.6, 0.2);
    float elevation = val * 0.5 + 0.5;
    vec3 col = mix(low, high, elevation);
    col = mix(col, vec3(0.1), line);
    fragColor = vec4(col, 1.0);
}
