#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a; vec2 b; vec3 c; vec4 d;
    if (r < 0.4) {
        a = 1.0;
        b = vec2(0.5, 0.3);
        c = vec3(0.8, 0.2, 0.1);
        d = vec4(1.0, 0.5, 0.3, 1.0);
    } else {
        a = 0.2;
        b = vec2(0.8, 0.6);
        c = vec3(0.1, 0.5, 0.9);
        d = vec4(0.3, 0.7, 0.4, 1.0);
    }
    vec3 col = c * a + b.xxy * d.rgb;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
