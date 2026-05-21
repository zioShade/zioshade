#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float h = fract(sin(dot(uv, vec2(127.1, 311.7))) * 43758.5);
    vec3 col;
    if (h < 0.33) {
        col = vec3(0.8, 0.2, 0.2);
    } else if (h < 0.66) {
        float check = step(0.5, fract(uv.x * 10.0));
        check += step(0.5, fract(uv.y * 10.0));
        col = mix(vec3(0.2, 0.3, 0.7), vec3(0.7, 0.8, 1.0), check);
    } else {
        col = vec3(0.2, 0.7, 0.3);
    }
    fragColor = vec4(col, 1.0);
}
