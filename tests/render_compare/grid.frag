#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    float scale = 16.0;
    vec2 grid = fract(uv * scale);
    float mask = step(0.05, grid.x) * step(0.05, grid.y);
    vec2 cid = floor(uv * scale);
    float checker = mod(cid.x + cid.y, 2.0);
    vec3 col = mix(vec3(0.1), vec3(0.9, 0.85, 0.7), checker * mask);
    FragColor = vec4(col, 1.0);
}
