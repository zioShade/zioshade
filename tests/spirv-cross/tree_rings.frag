#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Microscope cross-section of tree trunk (growth rings)
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Growth rings with varying width
    float ring_width = 0.05 + 0.02 * sin(a * 4.0);
    float rings = sin(r / ring_width) * 0.5 + 0.5;
    // Heartwood center
    float heart = smoothstep(0.1, 0.05, r);
    // Bark edge
    float bark = smoothstep(0.75, 0.73, r) * (1.0 - smoothstep(0.7, 0.68, r));
    vec3 sapwood = vec3(0.85, 0.7, 0.4);
    vec3 heartwood = vec3(0.55, 0.35, 0.15);
    vec3 col = mix(sapwood, heartwood, rings) * (1.0 - heart);
    col = mix(col, vec3(0.4, 0.25, 0.1), heart);
    col = mix(col, vec3(0.3, 0.2, 0.1), bark);
    col *= smoothstep(0.8, 0.75, r) + bark;
    fragColor = vec4(col, 1.0);
}
