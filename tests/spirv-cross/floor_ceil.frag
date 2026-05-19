#version 450

// Test: sign, floor, ceil, round patterns
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x * 4.0 - 2.0;
    float y = uv.y * 4.0 - 2.0;

    float a = floor(x);
    float b = ceil(x);
    float c = sign(y);
    float d = fract(x);

    float r = (a + 2.0) / 4.0;
    float g = (b + 2.0) / 4.0;
    float bl = d;

    gl_FragColor = vec4(clamp(r, 0.0, 1.0), clamp(g, 0.0, 1.0), bl, 1.0);
}
