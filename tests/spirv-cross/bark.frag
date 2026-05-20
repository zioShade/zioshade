#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Bark texture
    float n = sin(uv.y * 15.0 + sin(uv.x * 3.0) * 2.0) * 0.5 + 0.5;
    float n2 = sin(uv.y * 30.0 + cos(uv.x * 5.0) * 3.0) * 0.5 + 0.5;
    float vertical = sin(uv.x * 20.0 + uv.y * 0.5) * 0.5 + 0.5;
    float cracks = smoothstep(0.48, 0.5, n) * smoothstep(0.48, 0.5, n2);
    vec3 bark_light = vec3(0.5, 0.35, 0.2);
    vec3 bark_dark = vec3(0.3, 0.2, 0.1);
    vec3 col = mix(bark_dark, bark_light, n * vertical);
    col = mix(col, vec3(0.15, 0.1, 0.05), cracks);
    fragColor = vec4(col, 1.0);
}
