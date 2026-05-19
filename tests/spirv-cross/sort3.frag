#version 450

// Test: reverse/sort-like pattern with nested ifs
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float a = uv.x;
    float b = uv.y;
    float c = 1.0 - uv.x;

    // Sort a, b, c (simple 3-element sort)
    float lo, mid, hi;
    if (a <= b && b <= c) { lo = a; mid = b; hi = c; }
    else if (a <= c && c <= b) { lo = a; mid = c; hi = b; }
    else if (b <= a && a <= c) { lo = b; mid = a; hi = c; }
    else if (b <= c && c <= a) { lo = b; mid = c; hi = a; }
    else if (c <= a && a <= b) { lo = c; mid = a; hi = b; }
    else { lo = c; mid = b; hi = a; }

    gl_FragColor = vec4(lo, mid, hi, 1.0);
}
