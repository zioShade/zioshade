#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Dragon curve approximation with spirals
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Spiral dragon body
    float body_r = 0.3 + 0.15 * sin(a * 4.0);
    float body = smoothstep(body_r + 0.02, body_r - 0.02, r);
    // Scales pattern
    float scales = sin(a * 20.0) * sin(r * 30.0) * 0.5 + 0.5;
    vec3 scale_col = mix(vec3(0.1, 0.4, 0.1), vec3(0.2, 0.6, 0.2), scales);
    vec3 col = scale_col * body;
    // Eye
    float eye = smoothstep(0.04, 0.02, length(uv - vec2(0.15, 0.15)));
    col = mix(col, vec3(0.9, 0.7, 0.0), eye);
    col += vec3(0.05) * (1.0 - body);
    fragColor = vec4(col, 1.0);
}
