
#version 430
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(256.0, 256.0);
    vec3 col = vec3(0.0);
    if (uv.x > 0.3) {
        if (uv.y > 0.3) {
            col = vec3(1.0, 0.0, 0.0);
        } else {
            col = vec3(0.0, 1.0, 0.0);
        }
    } else {
        if (uv.y > 0.7) {
            col = vec3(0.0, 0.0, 1.0);
        } else {
            col = vec3(1.0, 1.0, 0.0);
        }
    }
    FragColor = vec4(col, 1.0);
}
