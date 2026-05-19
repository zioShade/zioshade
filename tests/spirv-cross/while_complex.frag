#version 450

// Test while loop with complex condition
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float y = uv.y;
    float sum = 0.0;
    int count = 0;

    while (sum < 0.9 && count < 20) {
        sum += x * y * 0.1;
        x *= 0.9;
        y *= 0.95;
        count++;
    }

    gl_FragColor = vec4(clamp(sum, 0.0, 1.0), float(count) / 20.0, x, 1.0);
}
