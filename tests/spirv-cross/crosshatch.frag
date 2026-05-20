#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Cross-hatch shading
    float r = length(uv);
    float hatch1 = smoothstep(0.02, 0.0, abs(mod(uv.x + uv.y, 0.1) - 0.05));
    float hatch2 = smoothstep(0.02, 0.0, abs(mod(uv.x - uv.y, 0.1) - 0.05));
    float shade = smoothstep(1.0, 0.3, r);
    float hatching = max(hatch1, hatch2) * shade;
    vec3 col = vec3(hatching * 0.7 + 0.1);
    fragColor = vec4(col, 1.0);
}
