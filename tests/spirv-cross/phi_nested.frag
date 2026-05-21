#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a; float b;
    if (r < 0.5) {
        a = 1.0;
        if (uv.x > 0.0) { b = 0.8; } else { b = 0.3; }
    } else {
        a = 0.5;
        if (uv.y > 0.0) { b = 0.6; } else { b = 0.1; }
    }
    vec3 col = vec3(a * b);
    fragColor = vec4(col, 1.0);
}
