// Tests: struct array iteration with conditional accumulation
#version 450
layout(location = 0) out vec4 fragColor;

struct Sample {
    vec2 position;
    float weight;
};

void main() {
    Sample samples[6];
    samples[0] = Sample(vec2(0.0, 0.0), 1.0);
    samples[1] = Sample(vec2(1.0, 0.0), 0.8);
    samples[2] = Sample(vec2(0.5, 0.86), 0.6);
    samples[3] = Sample(vec2(0.0, 1.0), 0.4);
    samples[4] = Sample(vec2(1.0, 1.0), 0.2);
    samples[5] = Sample(vec2(0.5, 0.0), 0.3);

    vec2 center = vec2(0.0);
    float totalWeight = 0.0;
    for (int i = 0; i < 6; i++) {
        center += samples[i].position * samples[i].weight;
        totalWeight += samples[i].weight;
    }
    center /= totalWeight;

    float dist = length(center - vec2(0.5));
    fragColor = vec4(vec3(1.0 - dist), 1.0);
}
