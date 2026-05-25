// Tests: float comparisons and boolean logic
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float a = 0.5;
    float b = 0.3;
    float c = 0.8;

    bool cond1 = a > b;
    bool cond2 = c < a;
    bool cond3 = cond1 && !cond2;
    bool cond4 = cond1 || cond2;

    float r = cond3 ? 1.0 : 0.0;
    float g = cond4 ? 1.0 : 0.0;
    float bl = (a == 0.5) ? 0.5 : 0.0;

    fragColor = vec4(r, g, bl, 1.0);
}
