// Test: nested switch with complex case values
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    int mode = int(gl_FragCoord.x + gl_FragCoord.y) % 12;
    vec3 color = vec3(0.0);
    
    switch (mode) {
        case 0: color = vec3(1.0, 0.0, 0.0); break;
        case 1: color = vec3(0.0, 1.0, 0.0); break;
        case 2: color = vec3(0.0, 0.0, 1.0); break;
        case 3: {
            int sub = int(gl_FragCoord.y) % 3;
            switch (sub) {
                case 0: color = vec3(1.0, 1.0, 0.0); break;
                case 1: color = vec3(0.0, 1.0, 1.0); break;
                default: color = vec3(1.0, 0.0, 1.0); break;
            }
            break;
        }
        case 4: 
        case 5: color = vec3(0.5); break;
        case 6: color = vec3(0.8, 0.2, 0.4); break;
        case 7: color = vec3(0.2, 0.8, 0.4); break;
        default: color = vec3(0.1); break;
    }
    
    fragColor = vec4(color, 1.0);
}
