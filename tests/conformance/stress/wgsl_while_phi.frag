// Tests: while loop with phi that modifies value used in loop body
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float val = 0.5;
    int i = 0;
    while (i < 10) {
        val = val * 0.9;
        float scaled = val * 2.0;
        if (scaled < 0.01) break;
        i++;
    }
    fragColor = vec4(vec3(val), 1.0);
}
