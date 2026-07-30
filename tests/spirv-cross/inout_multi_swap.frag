#version 310 es
precision highp float;
out vec4 fragColor;

// Regression: multiple inout params (void return). Pre-fix this hit the
// "multiple out params: return a struct" TODO and every write was lost.
void swap(inout float a, inout float b) {
    float t = a;
    a = b;
    b = t;
}

// Regression: non-void return + inout param. The return captures orig while
// the inout write must still propagate to the caller's variable.
float pop_and_add(inout float acc, float delta) {
    float prev = acc;
    acc = acc + delta;
    return prev;
}

void main() {
    float x = gl_FragCoord.x * 0.001;
    float y = gl_FragCoord.y * 0.001;
    swap(x, y);
    float prev = pop_and_add(x, 0.25);
    fragColor = vec4(prev, x, y, 1.0);
}
