#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Logistic map bifurcation visualization
    float x = uv.x;
    float y = 0.0;

    float r = uv.y * 4.0;
    float pop = 0.5;

    for (int i = 0; i < 64; i++) {
        pop = r * pop * (1.0 - pop);
        if (i > 32) {
            y += smoothstep(0.01, 0.0, abs(pop - x));
        }
    }

    float col = min(y, 1.0);
    vec3 color = mix(vec3(0.0), vec3(0.9, 0.3, 0.1), col);

    fragColor = vec4(color, 1.0);
}
