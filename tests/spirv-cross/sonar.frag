#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Sonar / radar display
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Sweep line
    float sweep_a = gl_FragCoord.x * 0.01;
    float sweep = smoothstep(0.05, 0.0, abs(mod(a - sweep_a, 6.28) - 0.0));
    // Range rings
    float rings = sin(r * 15.0) * 0.5 + 0.5;
    float ring_line = smoothstep(0.05, 0.02, abs(fract(r * 5.0) - 0.5));
    // Blips
    float blip1 = smoothstep(0.05, 0.03, length(uv - vec2(0.3, 0.2)));
    float blip2 = smoothstep(0.04, 0.02, length(uv - vec2(-0.2, 0.4)));
    vec3 col = vec3(0.0, 0.1, 0.0);
    col += vec3(0.0, 0.3, 0.0) * ring_line * 0.3;
    col += vec3(0.0, 0.5, 0.0) * sweep;
    col += vec3(0.0, 1.0, 0.0) * (blip1 + blip2);
    col *= smoothstep(0.9, 0.85, r);
    fragColor = vec4(col, 1.0);
}
