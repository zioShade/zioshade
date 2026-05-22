#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    // Multiple compound assignments on the same variable
    float val = 1.0;
    if (uv.x > 0.2) val += 0.3;
    if (uv.x > 0.4) val *= 1.5;
    if (uv.x > 0.6) val -= 0.2;
    if (uv.x > 0.8) val /= 2.0;

    // Different variable with compound
    vec3 col = vec3(0.2);
    col += vec3(val * 0.3);
    col *= vec3(0.8, 0.9, 1.0);
    col -= vec3(0.1);

    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
