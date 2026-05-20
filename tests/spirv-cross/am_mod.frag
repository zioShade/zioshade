#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Envelope / AM modulation visualization
    float carrier_freq = 30.0;
    float mod_freq = 3.0;
    float carrier = sin(uv.x * carrier_freq);
    float envelope = sin(uv.x * mod_freq) * 0.5 + 0.5;
    float am = carrier * envelope;
    // Draw signal
    float d_signal = abs(uv.y - am * 0.4);
    float d_env = abs(uv.y - envelope * 0.4);
    float d_env_neg = abs(uv.y + envelope * 0.4);
    vec3 col = vec3(0.05);
    col += vec3(0.3, 0.8, 0.3) * smoothstep(0.01, 0.005, d_signal);
    col += vec3(0.5, 0.3, 0.1) * smoothstep(0.005, 0.002, d_env);
    col += vec3(0.5, 0.3, 0.1) * smoothstep(0.005, 0.002, d_env_neg);
    fragColor = vec4(col, 1.0);
}
