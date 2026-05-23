#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // atan2 + degrees
    vec2 centered = uv - vec2(0.5);
    float angle = atan(centered.y, centered.x);
    float deg = degrees(angle);
    float norm = (deg + 180.0) / 360.0;
    fragColor = vec4(norm, norm, norm, 1.0);
}
