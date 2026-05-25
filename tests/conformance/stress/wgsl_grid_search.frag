// Tests: integer loop with float accumulation
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    int count = 0;
    float sum = 0.0;
    for (int x = 0; x < 16; x++) {
        for (int y = 0; y < 16; y++) {
            float fx = float(x) / 16.0;
            float fy = float(y) / 16.0;
            float d = sqrt(fx * fx + fy * fy);
            if (d < 0.5) {
                sum += d;
                count++;
            }
        }
    }
    float avg = sum / float(count + 1);
    fragColor = vec4(vec3(avg * 2.0), 1.0);
}
