#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Concentric rings with color cycling
    float r = length(uv);
    float rings = fract(r * 10.0);
    float ring_edge = smoothstep(0.03, 0.01, min(rings, 1.0 - rings));
    // Hue cycling based on radius
    float hue = r * 5.0;
    vec3 col = vec3(
        sin(hue * 6.28) * 0.5 + 0.5,
        sin(hue * 6.28 + 2.09) * 0.5 + 0.5,
        sin(hue * 6.28 + 4.18) * 0.5 + 0.5
    );
    col = mix(col * 0.3, col, ring_edge);
    col *= smoothstep(1.0, 0.9, r);
    fragColor = vec4(col, 1.0);
}
