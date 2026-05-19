#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 10.0;
    vec2 f = fract(uv);
    float lx = smoothstep(0.0, 0.05, f.x) * smoothstep(0.0, 0.05, 1.0 - f.x);
    float ly = smoothstep(0.0, 0.05, f.y) * smoothstep(0.0, 0.05, 1.0 - f.y);
    float grid = 1.0 - lx * ly;
    FragColor = vec4(vec3(grid * 0.5), 1.0);
}
