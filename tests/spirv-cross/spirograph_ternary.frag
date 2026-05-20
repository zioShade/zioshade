#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Spirograph with nested ternary for coloring
    float R = 0.5;
    float r_inner = 0.3;
    float d = 0.2;
    float min_dist = 1.0;
    for (int i = 0; i <= 60; i++) {
        float t = float(i) / 60.0 * 6.28 * 5.0;
        float x = (R - r_inner) * cos(t) + d * cos((R - r_inner) / r_inner * t);
        float y = (R - r_inner) * sin(t) - d * sin((R - r_inner) / r_inner * t);
        float dist = length(uv - vec2(x, y));
        min_dist = min(min_dist, dist);
    }
    float curve = smoothstep(0.01, 0.005, min_dist);
    // Complex ternary chain for color
    float angle = atan(uv.y, uv.x);
    vec3 col = angle > 1.0 ? vec3(0.9, 0.3, 0.1) :
               angle > 0.0 ? vec3(0.1, 0.7, 0.3) :
               angle > -1.0 ? vec3(0.1, 0.3, 0.9) :
               vec3(0.9, 0.9, 0.1);
    col *= curve;
    fragColor = vec4(col, 1.0);
}
