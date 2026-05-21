#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Topographic contour map with dFdx/dFdy
    float h = sin(uv.x * 0.8) * cos(uv.y * 0.6) + sin(uv.x * 0.3 + uv.y * 0.5) * 0.5;
    float contour = fract(h * 8.0);
    float line = smoothstep(0.03, 0.01, min(contour, 1.0 - contour));
    // Slope shading
    float dx = dFdx(h);
    float dy = dFdy(h);
    float slope = sqrt(dx * dx + dy * dy);
    vec3 low = vec3(0.15, 0.35, 0.15);
    vec3 high = vec3(0.6, 0.5, 0.3);
    vec3 col = mix(low, high, smoothstep(-1.0, 1.0, h));
    col *= 0.7 + 0.3 * (1.0 - slope * 3.0);
    col += vec3(0.3) * line;
    fragColor = vec4(col, 1.0);
}
