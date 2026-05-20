#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Ripple interference from two drops
    float d1 = length(uv - vec2(-0.3, 0.0));
    float d2 = length(uv - vec2(0.3, 0.0));
    float wave1 = sin(d1 * 40.0) / (d1 * 10.0 + 1.0);
    float wave2 = sin(d2 * 40.0) / (d2 * 10.0 + 1.0);
    float combined = wave1 + wave2;
    float height = combined * 0.5 + 0.5;
    vec3 col = mix(vec3(0.05, 0.1, 0.3), vec3(0.3, 0.6, 0.9), height);
    // Specular highlights
    float spec = pow(max(height, 0.0), 8.0);
    col += vec3(spec * 0.5);
    fragColor = vec4(col, 1.0);
}
