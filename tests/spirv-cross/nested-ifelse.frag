#version 450

layout(location = 0) in float u;
layout(location = 0) out vec4 fragColor;

void main()
{
    // Test nested if-else with comparisons
    float result;
    if (u < 0.25) {
        result = u * 4.0;
    } else if (u < 0.5) {
        result = 1.0 - (u - 0.25) * 4.0;
    } else if (u < 0.75) {
        result = (u - 0.5) * 4.0;
    } else {
        result = 1.0 - (u - 0.75) * 4.0;
    }
    fragColor = vec4(result, result * 0.5, result * 0.25, 1.0);
}
