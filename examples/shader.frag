#version 430

layout(binding = 0) uniform Globals {
    vec2 iResolution;
    float iTime;
} u;

layout(location = 0) out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u.iResolution;
    fragColor = vec4(uv, 0.5 + 0.5 * sin(u.iTime), 1.0);
}
