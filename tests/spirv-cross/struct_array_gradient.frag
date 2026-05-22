#version 310 es
precision highp float;
out vec4 fragColor;

// Vec4 swizzle write with array + struct + conditional
struct ColorStop {
    vec4 color;
    float pos;
};

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    ColorStop stops[3];
    stops[0].color = vec4(1.0, 0.0, 0.0, 1.0);
    stops[0].pos = 0.0;
    stops[1].color = vec4(0.0, 1.0, 0.0, 1.0);
    stops[1].pos = 0.5;
    stops[2].color = vec4(0.0, 0.0, 1.0, 1.0);
    stops[2].pos = 1.0;

    // Dynamic gradient lookup
    vec4 col = stops[0].color;
    for (int i = 0; i < 2; i++) {
        if (uv.x >= stops[i].pos && uv.x <= stops[i + 1].pos) {
            float t = (uv.x - stops[i].pos) / max(stops[i + 1].pos - stops[i].pos, 0.001);
            col = mix(stops[i].color, stops[i + 1].color, t);
        }
    }

    // Swizzle write on struct member
    if (uv.y > 0.5) {
        col.xz = col.zx; // swap red and blue
    }

    fragColor = vec4(clamp(col.rgb, 0.0, 1.0), 1.0);
}
