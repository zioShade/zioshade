#version 310 es
precision highp float;
out vec4 fragColor;

// Test: function returning array element via index
vec3 getArrayColor(int idx) {
    vec3 palette[4];
    palette[0] = vec3(0.8, 0.2, 0.1);
    palette[1] = vec3(0.1, 0.7, 0.2);
    palette[2] = vec3(0.1, 0.2, 0.8);
    palette[3] = vec3(0.8, 0.7, 0.1);
    idx = clamp(idx, 0, 3);
    return palette[idx];
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    int idx = int(floor(uv.x * 4.0 + 2.0));
    vec3 col = getArrayColor(idx);
    fragColor = vec4(col, 1.0);
}
