#version 310 es
precision highp float;
out vec4 fragColor;

// Mat2 column subscript write in branches
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    mat2 m = mat2(1.0, 0.0, 0.0, 1.0);

    if (uv.x > 0.5) {
        m[0] = vec2(cos(uv.x), sin(uv.x));
    } else {
        m[1] = vec2(-sin(uv.x), cos(uv.x));
    }

    vec2 result = m * uv;
    float val = length(result);
    vec3 col = vec3(fract(val), fract(val * 1.5), fract(val * 2.0));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
