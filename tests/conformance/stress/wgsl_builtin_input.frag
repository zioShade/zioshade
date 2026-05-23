#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    float r = uv.x;
    float g = uv.y;
    float b = 1.0 - uv.x - uv.y;
    fragColor = vec4(r, g, b, 1.0);
}
