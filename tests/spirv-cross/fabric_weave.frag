#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Fabric weave pattern
    vec2 grid = fract(uv * 10.0);
    float warp = smoothstep(0.45, 0.5, grid.x) * (1.0 - smoothstep(0.5, 0.55, grid.x));
    float weft = smoothstep(0.45, 0.5, grid.y) * (1.0 - smoothstep(0.5, 0.55, grid.y));
    float weave = max(warp, weft);
    // Twill pattern
    float offset = floor(uv.y * 10.0);
    float twill = smoothstep(0.3, 0.5, grid.x + fract(offset * 0.5));
    vec3 warp_col = vec3(0.6, 0.2, 0.1);
    vec3 weft_col = vec3(0.1, 0.2, 0.6);
    vec3 col = mix(warp_col, weft_col, twill);
    col *= 0.8 + weave * 0.4;
    fragColor = vec4(col, 1.0);
}
