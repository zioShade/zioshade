#version 310 es
precision highp float;
out vec4 fragColor;

// Forward reference function with struct param used before definition
struct Ray {
    vec2 origin;
    vec2 dir;
};

float trace(Ray r);

float trace(Ray r) {
    return length(r.dir) * 0.5 + r.origin.x;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    Ray r;
    r.origin = uv;
    r.dir = normalize(uv - 0.5);

    float t = trace(r);
    vec3 col = vec3(fract(t), fract(t * 1.5), fract(t * 2.5));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
