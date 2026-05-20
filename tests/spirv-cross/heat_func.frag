#version 310 es
precision highp float;
out vec4 fragColor;

vec3 heat(float t) {
    return mix(vec3(0.0, 0.0, 0.1), vec3(1.0, 0.3, 0.0), t)
         + vec3(0.0, t, 0.0) * step(0.5, t);
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Heat map from function
    float val = sin(uv.x * 5.0) * cos(uv.y * 5.0) * 0.5 + 0.5;
    vec3 col = heat(val);
    fragColor = vec4(col, 1.0);
}
