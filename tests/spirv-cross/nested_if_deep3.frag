#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec3 col = vec3(0.0);
    if (uv.x > 0.2) {
        col.r = 0.3;
        if (uv.y > 0.3) {
            col.g = 0.5;
            if (uv.x > 0.6) {
                col.b = 0.7;
            } else {
                col.b = 0.2;
            }
        } else {
            col.g = 0.1;
        }
    } else {
        col.r = 0.9;
    }
    FragColor = vec4(col, 1.0);
}
