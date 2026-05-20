#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Glitch art v2
    float hash = fract(sin(dot(floor(uv * 2.0), vec2(127.1, 311.7))) * 43758.5);
    vec3 col = vec3(uv.x / 10.0, uv.y / 10.0, 0.5 + 0.5 * sin(uv.x * 0.5));
    float glitch = step(0.92, fract(sin(floor(uv.y * 3.0) * 43.7) * 43758.5));
    float offset = (hash - 0.5) * 0.3 * glitch;
    col = vec3(col.x + offset, col.y, col.z - offset * 0.5);
    col *= 0.95 + 0.05 * sin(uv.y * 50.0);
    fragColor = vec4(col, 1.0);
}
