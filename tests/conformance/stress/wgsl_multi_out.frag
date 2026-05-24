// Tests: multiple output targets
#version 450
layout(location = 0) out vec4 fragColor0;
layout(location = 1) out vec4 fragColor1;

uniform float u_val;

void main() {
    fragColor0 = vec4(u_val, 0.0, 0.0, 1.0);
    fragColor1 = vec4(0.0, u_val, 0.0, 1.0);
}
