#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Magnet field lines (dipole)
    vec2 r = uv - vec2(5.0, 5.0);
    float r_len = length(r);
    float r3 = r_len * r_len * r_len + 0.001;
    // Dipole field components
    float bx = 3.0 * r.x * r.y / r3;
    float by = (2.0 * r.y * r.y - r.x * r.x) / r3;
    float field = sqrt(bx * bx + by * by);
    // Field lines via stream function
    float stream = r.x * r.x / (r_len * r_len + 0.01);
    float lines = sin(stream * 20.0) * 0.5 + 0.5;
    vec3 col = vec3(0.05);
    col += vec3(0.2, 0.4, 0.8) * lines * smoothstep(5.0, 1.0, field);
    // Poles
    col += vec3(0.9, 0.2, 0.2) * smoothstep(0.15, 0.1, length(uv - vec2(5.0, 4.5)));
    col += vec3(0.2, 0.2, 0.9) * smoothstep(0.15, 0.1, length(uv - vec2(5.0, 5.5)));
    fragColor = vec4(col, 1.0);
}
