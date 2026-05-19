#version 450

// Test do-while loop with accumulation
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float x = uv.x;
    float sum = 0.0;
    float val = x;
    int i = 0;
    do {
        sum += val;
        val *= 0.5;
        i++;
    } while (i < 8 && val > 0.01);

    gl_FragColor = vec4(clamp(sum, 0.0, 1.0), uv.y, val, 1.0);
}
