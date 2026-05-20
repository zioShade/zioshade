#version 310 es
precision highp float;
out vec4 fragColor;

struct ColorStop {
    float position;
    vec3 color;
};

vec3 sampleGradient(ColorStop a, ColorStop b, float t) {
    float f = (t - a.position) / (b.position - a.position);
    f = clamp(f, 0.0, 1.0);
    return mix(a.color, b.color, f);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Gradient with struct-based color stops
    ColorStop stop1 = ColorStop(0.0, vec3(0.1, 0.0, 0.3));
    ColorStop stop2 = ColorStop(0.3, vec3(0.6, 0.0, 0.4));
    ColorStop stop3 = ColorStop(0.6, vec3(1.0, 0.5, 0.0));
    ColorStop stop4 = ColorStop(1.0, vec3(1.0, 1.0, 0.5));
    float t = uv.x * 0.5 + 0.5;
    vec3 col;
    if (t < stop2.position) {
        col = sampleGradient(stop1, stop2, t);
    } else if (t < stop3.position) {
        col = sampleGradient(stop2, stop3, t);
    } else {
        col = sampleGradient(stop3, stop4, t);
    }
    fragColor = vec4(col, 1.0);
}
