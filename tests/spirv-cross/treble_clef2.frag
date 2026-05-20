#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Treble clef approximation using bezier-like curves
    float col_val = 0.0;
    // Vertical line
    float stem = smoothstep(0.015, 0.01, abs(uv.x + 0.02)) * step(-0.6, uv.y) * step(uv.y, 0.85);
    col_val += stem;
    // Bottom curl
    float curl_r = length(uv - vec2(-0.02, -0.5));
    float curl = smoothstep(0.18, 0.16, curl_r) * (1.0 - smoothstep(0.1, 0.08, curl_r));
    col_val += curl * step(uv.y, -0.2);
    // Top loop
    float loop_r = length(uv - vec2(-0.02, 0.6));
    float top_loop = smoothstep(0.12, 0.1, loop_r) * (1.0 - smoothstep(0.05, 0.03, loop_r));
    col_val += top_loop * step(0.4, uv.y);
    col_val = min(col_val, 1.0);
    vec3 col = vec3(0.05) + vec3(0.1) * col_val;
    fragColor = vec4(col, 1.0);
}
