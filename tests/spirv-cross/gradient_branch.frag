#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.01;
    // Gradient with multiple if-else branches, each modifying a variable
    vec3 col = vec3(0.0);
    float x = uv.x;
    
    if (x < 2.0) {
        col = vec3(0.8, 0.1, 0.1);
    } else if (x < 4.0) {
        col = vec3(0.8, 0.4, 0.1);
        col.g += (x - 2.0) * 0.3;
    } else if (x < 6.0) {
        col = vec3(0.1, 0.7, 0.1);
        col.g -= (x - 4.0) * 0.2;
        col.b += (x - 4.0) * 0.15;
    } else if (x < 8.0) {
        col = vec3(0.1, 0.2, 0.7);
        col.b -= (x - 6.0) * 0.2;
        col.r += (x - 6.0) * 0.15;
    } else {
        col = vec3(0.5, 0.1, 0.5);
    }
    
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
