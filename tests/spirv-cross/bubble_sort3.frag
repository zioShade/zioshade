#version 450

// Test: 3-element sort network with swaps
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = uv.x;
    float b = uv.y;
    float c = 1.0 - uv.x;

    // Bubble sort
    if (a > b) { float t = a; a = b; b = t; }
    if (b > c) { float t = b; b = c; c = t; }
    if (a > b) { float t = a; a = b; b = t; }

    gl_FragColor = vec4(a, b, c, 1.0);
}
