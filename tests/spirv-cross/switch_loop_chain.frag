#version 310 es
precision highp float;
out vec4 fragColor;

// Complex chain: switch inside loop, variable used across iterations
void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float accum = 0.0;
    vec3 col = vec3(0.0);
    
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float val;
        switch (i % 3) {
            case 0: val = sin(uv.x * fi); break;
            case 1: val = cos(uv.y * fi); break;
            case 2: val = sin(fi * 1.57); break;
            default: val = 0.0; break;
        }
        accum += val;
        if (accum > 2.0) accum -= 1.0;
        col += vec3(val * 0.15, val * 0.1, val * 0.05);
    }
    col += vec3(accum * 0.1);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
