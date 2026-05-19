#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float r = uv.x;
    float g = uv.y;
    vec2 rb = vec2(r, 0.5);
    vec3 col = vec3(rb, g);
    FragColor = vec4(col, 1.0);
}
