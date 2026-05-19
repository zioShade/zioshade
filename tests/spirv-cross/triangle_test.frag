#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    vec2 p1 = vec2(0.0, 0.7);
    vec2 p2 = vec2(-0.7, -0.5);
    vec2 p3 = vec2(0.7, -0.5);
    float d1 = (uv.x - p2.x) * (p1.y - p2.y) - (p1.x - p2.x) * (uv.y - p2.y);
    float d2 = (uv.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (uv.y - p3.y);
    float d3 = (uv.x - p1.x) * (p3.y - p1.y) - (p3.x - p1.x) * (uv.y - p1.y);
    bool inside = (d1 >= 0.0) && (d2 >= 0.0) && (d3 >= 0.0);
    vec3 col = inside ? vec3(0.9, 0.4, 0.2) : vec3(0.15);
    FragColor = vec4(col, 1.0);
}
