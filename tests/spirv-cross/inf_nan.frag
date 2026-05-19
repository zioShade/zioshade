#version 450

// Test: float precision patterns - isinf, isnan checks
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);

    float a = uv.x / max(uv.y, 0.001);
    a = clamp(a, -10.0, 10.0);

    float inf_val = 1.0 / 0.0;
    float nan_val = 0.0 / 0.0;

    bool is_inf = isinf(inf_val);
    bool is_nan = isnan(nan_val);

    float r = a / 10.0 * 0.5 + 0.5;
    float g = is_inf ? 1.0 : 0.0;
    float b = is_nan ? 1.0 : 0.0;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), g, b, 1.0);
}
