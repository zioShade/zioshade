// Tests: function with multiple inout parameters (swap pattern)
precision mediump float;
uniform vec2 u_input;

void swap(inout float a, inout float b) {
    float t = a;
    a = b;
    b = t;
}

void main() {
    float x = u_input.x;
    float y = u_input.y;
    swap(x, y);
    gl_FragColor = vec4(x, y, 0.0, 1.0);
}
