#version 460
layout(binding = 0) uniform sampler2D tex[4];

void main() {
    int idx = gl_DrawID & 3;
    gl_FragColor = texture(tex[idx], vec2(0.5));
}
