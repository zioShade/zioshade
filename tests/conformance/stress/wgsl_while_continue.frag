#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // while loop with continue
    float val = 0.0;
    int count = 0;
    while (val < uv.x) {
        val += 0.05;
        count++;
        if (count % 3 == 0) continue;
        val += 0.01;
    }
    fragColor = vec4(val, float(count) / 20.0, 0.5, 1.0);
}
