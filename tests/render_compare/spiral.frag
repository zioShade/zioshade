#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    vec2 p = uv * 4.0 - 2.0;
    float r = dot(p, p);
    float angle = atan(p.y, p.x);
    float spiral = sin(r * 3.0 - angle * 2.0);
    vec3 col = vec3(spiral * 0.5 + 0.5);
    FragColor = vec4(col, 1.0);
}
