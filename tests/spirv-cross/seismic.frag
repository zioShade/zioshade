#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Seismic wave propagation
    float epicenter = 7.0;
    float t = gl_FragCoord.x * 0.01;
    float d = abs(uv.x - epicenter);
    // P-wave (faster, weaker)
    float p_arrival = d * 0.5;
    float p_wave = sin((uv.y - p_arrival) * 20.0) * exp(-d * 0.3) * 0.3;
    // S-wave (slower, stronger)
    float s_arrival = d * 0.8;
    float s_wave = sin((uv.y - s_arrival) * 15.0) * exp(-d * 0.2) * 0.5;
    float combined = p_wave + s_wave;
    vec3 col = vec3(0.1);
    col += vec3(0.3, 0.5, 0.9) * max(p_wave, 0.0);
    col += vec3(0.9, 0.3, 0.2) * max(s_wave, 0.0);
    col += vec3(1.0, 0.5, 0.0) * smoothstep(0.1, 0.05, abs(uv.x - epicenter));
    fragColor = vec4(col, 1.0);
}
