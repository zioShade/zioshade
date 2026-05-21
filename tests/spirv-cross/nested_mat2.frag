#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    vec3 col = vec3(0.0);
    if (r < 0.5) {
        float x = sin(uv.x * 10.0);
        x += 0.5;
        if (x > 0.5) {
            x *= 2.0;
            col = vec3(x);
        } else {
            x -= 0.2;
            col = vec3(0.0, x, 0.0);
        }
    } else {
        float y = cos(uv.y * 10.0);
        y *= 1.5;
        if (y > 0.0) {
            y += 0.3;
            col = vec3(0.0, 0.0, y);
        } else {
            y = abs(y);
            col = vec3(y, y * 0.5, 0.0);
        }
    }
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
