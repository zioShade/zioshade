#version 310 es
precision highp float;
out vec4 fragColor;

vec2 polar_to_cart(float r, float angle) {
    return vec2(r * cos(angle), r * sin(angle));
}

float cart_to_polar(vec2 p) {
    return atan(p.y, p.x);
}

vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void main() {
    float angle = gl_FragCoord.x * 0.01;
    float r = gl_FragCoord.y * 0.005;
    vec2 cart = polar_to_cart(r, angle);
    float back = cart_to_polar(cart);
    vec3 col = hsv2rgb(vec3(back / 6.28, 0.8, 0.9));
    fragColor = vec4(col, 1.0);
}
