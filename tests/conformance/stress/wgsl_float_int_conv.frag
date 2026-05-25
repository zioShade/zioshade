// Tests: float to int conversion patterns
#version 450
layout(location = 0) out vec4 fragColor;

void main() {
    float f = 3.7;
    int i = int(f);
    int floor_i = int(floor(f));
    int ceil_i = int(ceil(f));
    float round_f = floor(f + 0.5);
    fragColor = vec4(float(i) / 10.0, float(floor_i) / 10.0, round_f / 10.0, float(ceil_i) / 10.0);
}
