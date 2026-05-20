#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Candy stripe with twist
    float angle = uv.y * 2.0;
    float twisted_x = uv.x * cos(angle) - uv.y * sin(angle);
    float stripe = sin(twisted_x * 8.0) * 0.5 + 0.5;
    vec3 red = vec3(0.9, 0.15, 0.2);
    vec3 white = vec3(0.95, 0.93, 0.9);
    vec3 col = mix(white, red, step(0.5, stripe));
    fragColor = vec4(col, 1.0);
}
