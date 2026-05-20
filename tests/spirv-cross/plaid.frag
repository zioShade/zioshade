#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Plaid / tartan with multiple overlaid stripe sets
    float s1 = sin(uv.x * 3.0) * 0.5 + 0.5;
    float s2 = sin(uv.x * 7.0 + 1.0) * 0.5 + 0.5;
    float s3 = sin(uv.y * 4.0) * 0.5 + 0.5;
    float s4 = sin(uv.y * 9.0 + 2.0) * 0.5 + 0.5;
    float h = step(0.6, s1) + step(0.6, s2) * 0.5;
    float v = step(0.6, s3) + step(0.6, s4) * 0.5;
    float plaid = h + v;
    vec3 red = vec3(0.7, 0.1, 0.1);
    vec3 green = vec3(0.1, 0.4, 0.1);
    vec3 navy = vec3(0.1, 0.1, 0.3);
    vec3 col = navy;
    col = mix(col, red, step(0.5, plaid));
    col = mix(col, green, step(1.5, plaid));
    fragColor = vec4(col, 1.0);
}
