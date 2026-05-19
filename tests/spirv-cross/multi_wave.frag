#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float w1 = sin(uv.x * 10.0) * 0.3;
    float w2 = sin(uv.x * 20.0) * 0.15;
    float w3 = sin(uv.x * 40.0) * 0.075;
    float wave = (w1 + w2 + w3) * 0.5 + uv.y;
    float col = smoothstep(0.48, 0.52, wave);
    gl_FragColor = vec4(col, col * 0.7, col * 0.3, 1.0);
}
