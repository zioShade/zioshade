#version 430
layout(location = 0) out vec4 FragColor;

// Test: atan2 (atan(y,x)) polar coordinates
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float angle = atan(p.y, p.x);
    float r = length(p);
    float sectors = floor(angle / 0.7854);  // 8 sectors
    float col = mod(sectors, 2.0);
    FragColor = vec4(col * r, r, angle / 6.2832, 1.0);
}
