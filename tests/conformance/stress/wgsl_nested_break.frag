// Tests: complex nested control flow with multiple breaks
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float result = 0.0;
    for (int i = 0; i < 10; i++) {
        float x = float(i) * 0.1;
        for (int j = 0; j < 5; j++) {
            float y = x + float(j) * 0.05;
            result += y;
            if (result > 3.0) break;
        }
        if (result > 3.0) break;
    }
    fragColor = vec4(vec3(fract(result)), 1.0);
}
