// Test: switch with fallthrough and complex conditions
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    int mode = int(gl_FragCoord.x) % 6;
    vec3 color = vec3(0.0);
    
    switch (mode) {
        case 0: color.r = 1.0; break;
        case 1: color.g = 1.0; break;
        case 2: color.b = 1.0; break;
        case 3: color.rg = vec2(1.0); break;
        case 4: color = vec3(0.5); break;
        default: color = vec3(0.1, 0.2, 0.3); break;
    }
    
    fragColor = vec4(color, 1.0);
}
