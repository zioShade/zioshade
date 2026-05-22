#version 310 es
precision highp float;
out vec4 fragColor;

// Multiple return paths from nested if/else inside a loop
float compute(vec2 uv) {
    for (int i = 0; i < 10; i++) {
        float x = uv.x * float(i + 1);
        if (x > 3.0) {
            return x * 0.5;
        } else if (x > 2.0) {
            return x * 0.3;
        } else if (x > 1.0) {
            continue;
        }
        uv.y += 0.01;
    }
    return uv.y;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;
    float val = compute(uv);
    vec3 col = vec3(fract(val));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
