#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // EEG / brain wave signals
    float t = uv.x;
    float alpha = sin(t * 30.0) * 0.15;
    float beta = sin(t * 70.0 + 1.0) * 0.05;
    float theta = sin(t * 12.0 + 2.0) * 0.2;
    float delta = sin(t * 5.0 + 3.0) * 0.3;
    float signal = alpha + beta + theta + delta + 0.5;
    float d = abs(uv.y - signal);
    float line = smoothstep(0.03, 0.01, d);
    float glow = smoothstep(0.1, 0.03, d) * 0.3;
    vec3 col = vec3(0.0, 0.3, 0.0);
    col += vec3(0.2, 1.0, 0.3) * (line + glow);
    // Grid
    col += vec3(0.05) * smoothstep(0.02, 0.01, min(fract(uv.x), fract(uv.y)));
    fragColor = vec4(col, 1.0);
}
