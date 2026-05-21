#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float val = 0.5;
    switch (99) {
        default: val = 0.3; break;
    }
    vec3 col = vec3(val);
    fragColor = vec4(col, 1.0);
}
