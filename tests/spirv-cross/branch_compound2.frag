#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    
    // Declare then assign in branches, then compound assign
    vec3 col = vec3(0.0);
    if (r < 0.3) {
        col = vec3(0.8, 0.2, 0.1);
    } else if (r < 0.6) {
        col = vec3(0.1, 0.6, 0.2);
    } else {
        col = vec3(0.1, 0.2, 0.5);
    }
    col += vec3(0.05) * sin(uv.x * 20.0);
    col *= smoothstep(1.0, 0.0, r * 0.8);
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
