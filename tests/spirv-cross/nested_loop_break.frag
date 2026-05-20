#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    float x = gl_FragCoord.x;
    float result = 0.0;
    
    for (int i = 0; i < 10; i++) {
        for (int j = 0; j < 10; j++) {
            result += float(i * j) * 0.001;
            if (result > 0.5) break;
        }
        if (result > 0.8) break;
    }
    
    fragColor = vec4(result);
}
