#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    int ix = int(uv.x * 8.0);
    int iy = int(uv.y * 8.0);
    float bx = float(ix % 2);
    float by = float(iy % 2);
    float checker = abs(bx - by);
    vec3 col = mix(vec3(0.2, 0.1, 0.1), vec3(0.9, 0.85, 0.7), checker);
    FragColor = vec4(col, 1.0);
}
