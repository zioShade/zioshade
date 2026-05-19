#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float d = length(uv - 0.5);
    float cone = 1.0 - d * 2.0;
    gl_FragColor = vec4(clamp(cone, 0.0, 1.0), uv.y * 0.5, 0.3, 1.0);
}
