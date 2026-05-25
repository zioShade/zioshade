// Tests: complex loop with nested conditionals and state
#version 450
layout(location = 0) out vec4 fragColor;
uniform float u_seed;

void main() {
    float energy = u_seed;
    float position = 0.0;
    float velocity = 1.0;
    int steps = 0;

    while (energy > 0.01 && steps < 100) {
        float force = -position * 0.5;
        velocity += force * 0.1;
        position += velocity * 0.1;
        energy *= 0.95;

        if (abs(position) > 2.0) {
            velocity = -velocity * 0.8;
            position = clamp(position, -2.0, 2.0);
        }

        if (energy < 0.1) {
            velocity *= 0.5;
        }

        steps++;
    }

    fragColor = vec4(fract(position), fract(velocity), fract(energy), float(steps) / 100.0);
}
