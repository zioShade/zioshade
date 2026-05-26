// Test: fragment shader with gl_FrontFacing and gl_PointCoord
#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_PointCoord;
    
    if (gl_FrontFacing) {
        float d = length(uv - 0.5);
        if (d > 0.5) discard;
        fragColor = vec4(1.0 - d * 2.0, 0.3, 0.5, 1.0);
    } else {
        fragColor = vec4(0.2, 0.2, 0.3, 0.5);
    }
}
