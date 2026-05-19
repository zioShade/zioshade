#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float sum = 0.0;
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4; j++) {
            float fi = float(i) * 0.25 + 0.125;
            float fj = float(j) * 0.25 + 0.125;
            float d = length(uv - vec2(fi, fj));
            sum += smoothstep(0.15, 0.0, d);
        }
    }
    sum = min(sum, 1.0);
    FragColor = vec4(vec3(sum), 1.0);
}
