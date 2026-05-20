#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Color wheel in HSV space
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float hue = a / 6.28 + 0.5;
    // Convert HSV to RGB
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(vec3(hue) + K.xyz) * 6.0 - K.www);
    vec3 col = mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), 0.9);
    float sat = smoothstep(0.0, 0.15, r) * (1.0 - smoothstep(0.8, 0.95, r));
    col *= sat;
    fragColor = vec4(col, 1.0);
}
