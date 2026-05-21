#version 310 es
precision highp float;
out vec4 fragColor;

struct Star2 { vec2 pos; float brightness; vec3 color; };

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    Star2 stars[5];
    stars[0] = Star2(vec2(-0.5, 0.3), 1.0, vec3(1.0, 0.9, 0.7));
    stars[1] = Star2(vec2(0.2, -0.4), 0.8, vec3(0.7, 0.8, 1.0));
    stars[2] = Star2(vec2(0.7, 0.1), 0.6, vec3(1.0, 1.0, 0.8));
    stars[3] = Star2(vec2(-0.3, -0.6), 0.9, vec3(0.8, 0.7, 1.0));
    stars[4] = Star2(vec2(0.4, 0.5), 0.7, vec3(1.0, 0.8, 0.6));
    vec3 col = vec3(0.02, 0.02, 0.06);
    for (int i = 0; i < 5; i++) {
        float d = length(uv - stars[i].pos);
        float glow = stars[i].brightness / (d * d + 0.01);
        glow = min(glow, 2.0);
        col += stars[i].color * glow * 0.02;
    }
    fragColor = vec4(col, 1.0);
}
