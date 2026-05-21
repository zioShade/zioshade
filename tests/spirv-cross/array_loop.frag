#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float weights[4];
    weights[0] = 0.4;
    weights[1] = 0.3;
    weights[2] = 0.2;
    weights[3] = 0.1;
    
    vec3 col = vec3(0.0);
    for (int i = 0; i < 4; i++) {
        float offset = float(i) * 0.1 - 0.15;
        float d = abs(uv.x - offset);
        col += vec3(weights[i] / (d + 0.05));
    }
    col /= 4.0;
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
