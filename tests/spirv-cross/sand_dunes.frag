#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Sand dunes
    float dune1 = sin(uv.x * 0.5 + sin(uv.y * 0.3) * 2.0) * 0.3;
    float dune2 = sin(uv.x * 0.8 + uv.y * 0.2 + 1.0) * 0.2;
    float height = dune1 + dune2;
    // Shadow based on slope
    float slope = dFdx(height);
    float shadow = smoothstep(-0.1, 0.1, slope);
    vec3 sand = vec3(0.85, 0.75, 0.55);
    vec3 shadow_col = vec3(0.6, 0.5, 0.35);
    vec3 col = mix(shadow_col, sand, shadow);
    fragColor = vec4(col, 1.0);
}
