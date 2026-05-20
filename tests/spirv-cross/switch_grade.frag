#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Complex switch-based color grading
    float region = floor((atan(uv.y, uv.x) + 3.14) / 1.57);
    vec3 col;
    switch (int(region)) {
        case 0:
            col = vec3(0.8, 0.3, 0.2) * length(uv);
            break;
        case 1:
            col = vec3(0.2, 0.7, 0.3) * length(uv);
            break;
        case 2:
            col = vec3(0.2, 0.3, 0.8) * length(uv);
            break;
        case 3:
            col = vec3(0.8, 0.7, 0.2) * length(uv);
            break;
        default:
            col = vec3(0.5);
            break;
    }
    fragColor = vec4(col, 1.0);
}
