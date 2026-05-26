// Test: complex state machine with switch
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    int state = 0;
    vec3 color = vec3(0.0);
    
    for (int i = 0; i < 8; i++) {
        switch (state) {
            case 0:  // Initialize
                color = vec3(0.1);
                state = 1;
                break;
            case 1:  // Add red
                color.r += 0.1;
                state = (color.r > 0.5) ? 2 : 1;
                break;
            case 2:  // Add green
                color.g += 0.1;
                state = (color.g > 0.5) ? 3 : 2;
                break;
            case 3:  // Add blue
                color.b += 0.1;
                state = (color.b > 0.3) ? 4 : 3;
                break;
            case 4:  // Fade
                color *= 0.8;
                state = 5;
                break;
            default:  // Done
                break;
        }
    }
    
    fragColor = vec4(color, 1.0);
}
