#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Abstract painting (Kandinsky-inspired)
    float t = gl_FragCoord.x * 0.002;
    // Background gradient
    vec3 col = mix(vec3(0.95, 0.9, 0.85), vec3(0.85, 0.9, 0.95), uv.y / 15.0);
    // Circles
    float c1 = smoothstep(2.1, 2.0, length(uv - vec2(3.0, 4.0)));
    float c2 = smoothstep(1.5, 1.4, length(uv - vec2(7.0, 6.0)));
    float c3 = smoothstep(1.0, 0.9, length(uv - vec2(5.0, 2.0)));
    float c4 = smoothstep(3.0, 2.9, length(uv - vec2(10.0, 5.0)));
    col = mix(col, vec3(0.8, 0.1, 0.1), c1);
    col = mix(col, vec3(0.1, 0.1, 0.8), c2);
    col = mix(col, vec3(0.9, 0.7, 0.0), c3);
    col = mix(col, vec3(0.1, 0.6, 0.1), c4);
    // Lines
    float line1 = smoothstep(0.05, 0.0, abs(uv.y - 3.0 - sin(uv.x * 0.5) * 2.0));
    col = mix(col, vec3(0.0), line1);
    fragColor = vec4(col, 1.0);
}
