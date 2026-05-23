#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // for loop with break
    float sum = 0.0;
    for (int i = 0; i < 10; i++) {
        sum += float(i) * 0.1;
        if (sum > uv.x) break;
    }
    fragColor = vec4(sum, sum, sum, 1.0);
}
