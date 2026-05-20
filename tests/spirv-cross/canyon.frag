#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Desert canyon layers
    vec3 col = vec3(0.5, 0.65, 0.9); // sky
    // Layer 1 (far)
    float h1 = 3.0 + sin(uv.x * 0.4) * 1.5 + cos(uv.x * 0.9 + 1.0) * 0.8;
    vec3 layer1 = vec3(0.75, 0.55, 0.35);
    col = mix(col, layer1, step(h1, uv.y));
    // Layer 2 (mid)
    float h2 = 2.5 + sin(uv.x * 0.6 + 2.0) * 1.8 + cos(uv.x * 1.2) * 0.5;
    vec3 layer2 = vec3(0.6, 0.4, 0.25);
    col = mix(col, layer2, step(h2, uv.y));
    // Layer 3 (near)
    float h3 = 1.5 + sin(uv.x * 0.8 + 4.0) * 1.5 + sin(uv.x * 2.0) * 0.3;
    vec3 layer3 = vec3(0.45, 0.3, 0.18);
    col = mix(col, layer3, step(h3, uv.y));
    // Ground
    col = mix(col, vec3(0.7, 0.6, 0.4), step(1.0, uv.y));
    fragColor = vec4(col, 1.0);
}
