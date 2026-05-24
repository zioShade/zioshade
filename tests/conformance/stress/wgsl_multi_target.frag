// Tests: multiple render targets (layout location)
#version 450
uniform vec4 u_color0;
uniform vec4 u_color1;

layout(location = 0) out vec4 fragColor0;
layout(location = 1) out vec4 fragColor1;

void main() {
    fragColor0 = u_color0;
    fragColor1 = u_color1;
}
