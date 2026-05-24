// Tests: struct inout parameter
precision mediump float;
uniform vec2 u_resolution;

struct Color {
    float r;
    float g;
    float b;
};

void clamp_color(inout Color c) {
    c.r = clamp(c.r, 0.0, 1.0);
    c.g = clamp(c.g, 0.0, 1.0);
    c.b = clamp(c.b, 0.0, 1.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    Color col;
    col.r = uv.x * 2.0;
    col.g = uv.y * 2.0;
    col.b = 0.5;
    clamp_color(col);
    gl_FragColor = vec4(col.r, col.g, col.b, 1.0);
}
