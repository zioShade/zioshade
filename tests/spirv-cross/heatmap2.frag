#version 310 es
precision highp float;
out vec4 fragColor;

vec3 heatMap2(float t) {
    if (t < 0.25) return mix(vec3(0.0, 0.0, 0.5), vec3(0.0, 0.5, 1.0), t * 4.0);
    if (t < 0.5) return mix(vec3(0.0, 0.5, 1.0), vec3(0.0, 1.0, 0.0), (t - 0.25) * 4.0);
    if (t < 0.75) return mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 1.0, 0.0), (t - 0.5) * 4.0);
    return mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), (t - 0.75) * 4.0);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float val = sin(uv.x * 5.0) * cos(uv.y * 5.0) * 0.5 + 0.5;
    vec3 col = heatMap2(val);
    fragColor = vec4(col, 1.0);
}
