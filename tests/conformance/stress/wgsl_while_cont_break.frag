// Tests: while loop with continue and break
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float sum = 0.0;
    int count = 0;
    int i = 0;
    while (i < 50) {
        i++;
        if (i % 3 == 0) continue;
        sum += float(i) * 0.1;
        count++;
        if (count >= 10) break;
    }
    fragColor = vec4(fract(sum), float(count) / 10.0, 0.0, 1.0);
}
