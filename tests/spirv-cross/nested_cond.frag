#version 310 es
precision highp float;
out vec4 fragColor;

// Test: deeply nested conditional with variable tracking
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float x = uv.x;
    float y = uv.y;
    float val = 0.0;
    if (x > 0.0) {
        if (y > 0.0) {
            val = x + y;
        } else {
            val = x - y;
        }
    } else {
        if (y > 0.0) {
            val = -x + y;
        } else {
            val = -x - y;
        }
    }
    vec3 col = vec3(val * 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
