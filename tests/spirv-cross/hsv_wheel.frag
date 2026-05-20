#version 310 es
precision highp float;
out vec4 fragColor;

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;
    float hue = uv.x;
    float sat = 1.0 - uv.y * 0.5;
    float val = 0.5 + uv.y * 0.5;
    vec3 col = hsv2rgb(vec3(hue, sat, val));
    fragColor = vec4(col, 1.0);
}
