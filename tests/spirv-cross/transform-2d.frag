#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Matrix transformations on a 2D point
    vec2 p = uv * 2.0 - 1.0;

    // Scale
    vec2 scaled = p * 0.8;

    // Rotate 45 degrees
    float angle = 0.7854;  // PI/4
    float c = cos(angle);
    float s = sin(angle);
    vec2 rotated = vec2(c * scaled.x - s * scaled.y, s * scaled.x + c * scaled.y);

    // Translate
    vec2 translated = rotated + vec2(0.1, -0.1);

    // Apply inverse to get original pattern
    vec2 inverse = vec2(c * (translated.x - 0.1) + s * (translated.y + 0.1),
                       -s * (translated.x - 0.1) + c * (translated.y + 0.1));
    inverse /= 0.8;

    // Checkerboard on inverse
    float check = mod(floor(inverse.x * 4.0) + floor(inverse.y * 4.0), 2.0);

    fragColor = vec4(vec3(check), 1.0);
}
