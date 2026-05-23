#version 450
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x / 800.0;
    float y = gl_FragCoord.y / 600.0;
    vec3 col = vec3(x, y, 0.5);
    fragColor = vec4(col, 1.0);
}
