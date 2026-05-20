#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Yin-yang symbol
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    // Outer circle
    float outer = step(r, 0.8);
    // S-curve dividing line
    float top_bump = length(uv - vec2(0.0, 0.35));
    float bot_bump = length(uv - vec2(0.0, -0.35));
    float dark = step(uv.y, 0.0);
    dark = mix(dark, 1.0, step(top_bump, 0.35));
    dark = mix(dark, 0.0, step(bot_bump, 0.35));
    // Dots
    float dot1 = step(length(uv - vec2(0.0, 0.35)), 0.1);
    float dot2 = step(length(uv - vec2(0.0, -0.35)), 0.1);
    dark = mix(dark, 0.0, dot1);
    dark = mix(dark, 1.0, dot2);
    vec3 col = mix(vec3(1.0), vec3(0.05), dark) * outer;
    fragColor = vec4(col, 1.0);
}
