#version 310 es
precision highp float;
out vec4 fragColor;

// Early return from multiple branches in a function
float pattern(vec2 uv) {
    float d = length(uv - 0.5);

    if (d > 0.45) return 0.0;
    if (d > 0.4) return 0.3;

    float angle = atan(uv.y - 0.5, uv.x - 0.5);
    int sector = int(floor(angle * 3.0 / 3.14159));

    if (sector == 0) return 0.8;
    if (sector == 1) return 0.6;
    return 0.4;
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;
    float val = pattern(uv);
    vec3 col = vec3(val);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
