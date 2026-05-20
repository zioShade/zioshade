#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Gradient palette with smooth stops
    float t = uv.x / 15.0;
    // Multiple color stops
    vec3 stops[5];
    stops[0] = vec3(0.1, 0.0, 0.2);
    stops[1] = vec3(0.6, 0.1, 0.4);
    stops[2] = vec3(1.0, 0.5, 0.1);
    stops[3] = vec3(1.0, 0.9, 0.3);
    stops[4] = vec3(0.2, 0.8, 0.5);
    vec3 col;
    if (t < 0.25) col = mix(stops[0], stops[1], t / 0.25);
    else if (t < 0.5) col = mix(stops[1], stops[2], (t - 0.25) / 0.25);
    else if (t < 0.75) col = mix(stops[2], stops[3], (t - 0.5) / 0.25);
    else col = mix(stops[3], stops[4], (t - 0.75) / 0.25);
    fragColor = vec4(col, 1.0);
}
