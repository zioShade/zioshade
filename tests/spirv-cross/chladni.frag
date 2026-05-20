#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Chladni figure (vibrating plate patterns)
    float m = 3.0;
    float n = 2.0;
    float pattern = sin(m * 3.14159 * uv.x) * sin(n * 3.14159 * uv.y) +
                    sin(n * 3.14159 * uv.x) * sin(m * 3.14159 * uv.y);
    float nodal = smoothstep(0.05, 0.0, abs(pattern));
    vec3 col = mix(vec3(0.6, 0.4, 0.2), vec3(0.1), nodal);
    col *= 0.8 + 0.2 * abs(pattern);
    fragColor = vec4(col, 1.0);
}
