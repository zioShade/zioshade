#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Spirograph pattern
    float R = 0.5;
    float r_inner = 0.3;
    float d = 0.2;
    float t = gl_FragCoord.x * 0.05;
    vec2 sp = vec2(
        (R - r_inner) * cos(t) + d * cos((R - r_inner) / r_inner * t),
        (R - r_inner) * sin(t) - d * sin((R - r_inner) / r_inner * t)
    );
    float dist = length(uv - sp * 0.8);
    float line = smoothstep(0.02, 0.01, dist);
    vec3 col = vec3(line) * vec3(0.3, 0.6, 0.9);
    fragColor = vec4(col, 1.0);
}
