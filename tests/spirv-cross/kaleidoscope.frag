#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float a = atan(uv.y, uv.x);
    float r = length(uv);
    a = mod(a, 1.0472);  // 60 degree segments
    vec2 p = vec2(cos(a), sin(a)) * r;
    float pattern = sin(p.x * 20.0) * sin(p.y * 20.0);
    vec3 col = vec3(pattern * 0.5 + 0.5);
    gl_FragColor = vec4(col, 1.0);
}
