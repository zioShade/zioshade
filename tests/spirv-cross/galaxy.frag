#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Spiral galaxy
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Logarithmic spiral arms
    float arm1 = sin(a * 2.0 - log(r + 0.01) * 5.0) * 0.5 + 0.5;
    float arm2 = sin(a * 2.0 - log(r + 0.01) * 5.0 + 3.14) * 0.5 + 0.5;
    // Brightness falls off from center
    float brightness = exp(-r * 2.0);
    // Core
    float core = exp(-r * r * 20.0);
    vec3 col = vec3(0.0);
    col += vec3(0.5, 0.3, 0.8) * arm1 * brightness;
    col += vec3(0.3, 0.5, 0.9) * arm2 * brightness;
    col += vec3(1.0, 0.9, 0.7) * core;
    // Background stars
    float star = fract(sin(dot(floor(uv * 200.0), vec2(127.1, 311.7))) * 43758.5);
    col += vec3(step(0.98, star)) * 0.2;
    fragColor = vec4(col, 1.0);
}
