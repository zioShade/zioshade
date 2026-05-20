#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Origami / folded paper
    float fold1 = step(0.0, uv.x + uv.y);
    float fold2 = step(0.0, uv.x - uv.y);
    // Light/shadow based on face orientation
    float shade1 = 0.5 + 0.3 * uv.x;
    float shade2 = 0.4 + 0.3 * uv.y;
    float shade3 = 0.6 - 0.2 * uv.x;
    vec3 paper = vec3(0.95, 0.93, 0.88);
    vec3 col = paper;
    if (fold1 > 0.5 && fold2 > 0.5) {
        col *= shade1;
    } else if (fold1 > 0.5) {
        col *= shade2;
    } else {
        col *= shade3;
    }
    fragColor = vec4(col, 1.0);
}
