// Tests: multiple render targets (layout location)
#version 450
layout(location = 0) out vec4 fragColor0;
layout(location = 1) out vec4 fragColor1;

void main() {
    vec2 uv = gl_FragCoord.xy / vec2(800.0, 600.0);
    
    fragColor0 = vec4(uv, 0.5, 1.0);
    fragColor1 = vec4(1.0 - uv.x, 1.0 - uv.y, 0.5, 1.0);
}
