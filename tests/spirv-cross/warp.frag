#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    vec2 p = uv * 2.0 - 1.0;
    float r = length(p);
    float a = atan(p.y, p.x);
    vec2 warped = vec2(cos(a + r * 3.0), sin(a + r * 3.0)) * r;
    vec3 col = vec3(warped * 0.5 + 0.5, 0.5);
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
