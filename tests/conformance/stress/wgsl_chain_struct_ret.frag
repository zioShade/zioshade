// Tests: chained function calls returning structs
#version 450
layout(location = 0) out vec4 fragColor;

struct Color { float r; float g; float b; };

Color makeColor(float r, float g, float b) {
    Color c;
    c.r = r;
    c.g = g;
    c.b = b;
    return c;
}

Color desaturate(Color c, float amount) {
    float grey = (c.r + c.g + c.b) / 3.0;
    Color result;
    result.r = mix(c.r, grey, amount);
    result.g = mix(c.g, grey, amount);
    result.b = mix(c.b, grey, amount);
    return result;
}

void main() {
    Color base = makeColor(1.0, 0.5, 0.2);
    Color desat = desaturate(base, 0.6);
    fragColor = vec4(desat.r, desat.g, desat.b, 1.0);
}
