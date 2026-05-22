#version 310 es
precision highp float;
out vec4 fragColor;

// Mat2 chain multiply in branches with struct
struct Transform2D {
    mat2 rot;
    vec2 offset;
};

mat2 rotate2d(float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return mat2(c, -s, s, c);
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Transform2D t1;
    t1.rot = rotate2d(uv.x * 3.14);
    t1.offset = vec2(0.5);

    Transform2D t2;
    t2.rot = rotate2d(uv.y * 1.57);
    t2.offset = vec2(0.3);

    mat2 combined;
    if (uv.x > 0.5) {
        combined = t1.rot * t2.rot;
    } else {
        combined = t2.rot * t1.rot;
    }

    vec2 result = combined * (uv - 0.5) + t1.offset;
    float val = length(result);

    vec3 col = vec3(fract(val), fract(val * 1.5), fract(val * 2.0));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
