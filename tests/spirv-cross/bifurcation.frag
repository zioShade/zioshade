#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Verhulst logistic map bifurcation diagram
    float x = uv.x * 3.0 + 2.5; // r from 2.5 to 5.5
    float y = uv.y;
    // Iterate logistic map
    float pop = 0.5;
    for (int i = 0; i < 30; i++) {
        pop = x * pop * (1.0 - pop);
        if (i > 15) {
            float d = abs(pop - y);
            float dot = smoothstep(0.005, 0.0, d);
            // Color based on iteration count
            vec3 iter_col = vec3(
                sin(float(i) * 0.5) * 0.5 + 0.5,
                sin(float(i) * 0.5 + 2.09) * 0.5 + 0.5,
                sin(float(i) * 0.5 + 4.18) * 0.5 + 0.5
            );
        }
    }
    float d = abs(pop - y);
    float dot = smoothstep(0.01, 0.0, d);
    vec3 col = vec3(0.0) + vec3(0.8, 0.5, 0.2) * dot;
    fragColor = vec4(col, 1.0);
}
