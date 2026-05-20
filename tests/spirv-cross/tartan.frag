#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Woven tartan / plaid pattern
    float h1 = sin(uv.x * 2.0) * 0.5 + 0.5;
    float h2 = sin(uv.y * 3.0) * 0.5 + 0.5;
    // Two overlapping stripe sets
    float stripe_h = step(0.5, fract(uv.x * 1.5));
    float stripe_v = step(0.5, fract(uv.y * 2.0));
    // Color mixing
    vec3 red = vec3(0.7, 0.1, 0.1);
    vec3 green = vec3(0.1, 0.4, 0.1);
    vec3 dark = vec3(0.15, 0.05, 0.05);
    vec3 col = dark;
    col = mix(col, red, stripe_h);
    col = mix(col, green, stripe_v);
    // Intersection highlight using && on floats
    float both = stripe_h && stripe_v;
    col = mix(col, vec3(0.9, 0.7, 0.2), both * 0.5);
    fragColor = vec4(col, 1.0);
}
