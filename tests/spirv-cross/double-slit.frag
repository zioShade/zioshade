#version 450

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 fragColor;

void main() {
    // Double-slit experiment simulation
    float sum = 0.0;
    float slit_sep = 0.15;
    float slit_width = 0.02;

    for (int i = -8; i <= 8; i++) {
        float slit_x = float(i) * slit_sep / 8.0;
        float dx = uv.x - slit_x - 0.5;
        float dy = uv.y - 0.3;
        float d = sqrt(dx * dx + dy * dy);
        float amp = sin(d * 60.0) / (d * 10.0 + 0.1);

        // Only from slit positions
        float in_slit = step(abs(slit_x - 0.0) - slit_width, 0.0);
        in_slit += step(abs(slit_x - slit_sep) - slit_width, 0.0);
        in_slit = min(in_slit, 1.0);

        sum += amp * in_slit;
    }

    float intensity = sum * sum;
    vec3 col = vec3(intensity * 0.5);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
