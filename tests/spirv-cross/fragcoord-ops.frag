#version 450

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 fc = gl_FragCoord;
    float depth = gl_FragCoord.z;
    vec2 screen = gl_FragCoord.xy;
    fragColor = vec4(screen / 800.0, depth, fc.w);
}
