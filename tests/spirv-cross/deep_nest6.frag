#version 310 es
precision highp float;
out vec4 fragColor;

// Deeply nested control flow with variable assignments at each level
void main() {
    vec2 uv = gl_FragCoord.xy / 300.0;

    float a = 0.0;
    float b = 0.0;
    float c = 0.0;

    if (uv.x > 0.1) {
        a = 0.2;
        if (uv.y > 0.1) {
            b = 0.3;
            if (uv.x > 0.3) {
                c = 0.4;
                if (uv.y > 0.3) {
                    a += 0.1;
                    if (uv.x > 0.5) {
                        b += 0.15;
                        if (uv.y > 0.5) {
                            c += 0.2;
                        } else {
                            c -= 0.1;
                        }
                    } else {
                        b -= 0.05;
                    }
                } else {
                    a -= 0.1;
                }
            } else {
                c = 0.1;
            }
        } else {
            b = 0.1;
        }
    } else {
        a = 0.05;
    }

    float val = a + b + c;
    vec3 col = vec3(val, fract(val * 2.0), fract(val * 3.0));
    fragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
