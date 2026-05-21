#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float x = uv.x;
    vec3 col;
    if (x < -0.75) col = vec3(0.8, 0.1, 0.1);
    else if (x < -0.5) col = vec3(0.8, 0.5, 0.1);
    else if (x < -0.25) col = vec3(0.8, 0.8, 0.1);
    else if (x < 0.0) col = vec3(0.1, 0.8, 0.1);
    else if (x < 0.25) col = vec3(0.1, 0.8, 0.8);
    else if (x < 0.5) col = vec3(0.1, 0.1, 0.8);
    else if (x < 0.75) col = vec3(0.5, 0.1, 0.8);
    else col = vec3(0.8, 0.1, 0.5);
    fragColor = vec4(col, 1.0);
}
