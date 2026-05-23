#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // Sign function
    float sx = sign(uv.x - 0.5);
    float sy = sign(uv.y - 0.5);
    float r = (sx + 1.0) * 0.5;
    float g = (sy + 1.0) * 0.5;
    fragColor = vec4(r, g, 0.5, 1.0);
}
