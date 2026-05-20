#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    float y = gl_FragCoord.y;
    float r = 0.0;
    
    // Deeply nested if-else
    if (x > 150.0) {
        if (y > 150.0) {
            r = 1.0;
        } else if (y > 100.0) {
            r = 0.75;
        } else {
            r = 0.5;
        }
    } else if (x > 100.0) {
        if (y > 100.0) {
            r = 0.4;
        } else {
            r = 0.3;
        }
    } else if (x > 50.0) {
        r = 0.2;
    } else {
        r = 0.1;
    }
    
    fragColor = vec4(r);
}
