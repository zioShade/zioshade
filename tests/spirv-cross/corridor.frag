#version 450
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0) * 2.0 - 1.0;
    float d = length(uv);
    float a = atan(uv.y, uv.x);
    float corridor = sin(a * 4.0 + d * 10.0) * 0.5 + 0.5;
    corridor /= (d + 0.5);
    gl_FragColor = vec4(clamp(corridor, 0.0, 1.0), clamp(corridor * 0.7, 0.0, 1.0), clamp(corridor * 0.3, 0.0, 1.0), 1.0);
}
