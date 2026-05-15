#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Test while loop with continue
    int count = 0;
    int j = 0;
    while (j < 8) {
        j++;
        if (j % 2 == 0) continue;
        count++;
    }

    fragColor = vec4(float(count) / 4.0, uv.x, uv.y, 1.0);
}
