// Tests: multiple render targets
#version 450
layout(location = 0) out vec4 fragColor0;
layout(location = 1) out vec4 fragColor1;

void main() {
    fragColor0 = vec4(1.0, 0.5, 0.0, 1.0);
    fragColor1 = vec4(0.0, 0.5, 1.0, 1.0);
}
