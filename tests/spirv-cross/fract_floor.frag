#version 450
layout(location = 0) out vec4 FragColor;
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float scaled = uv.x * 5.0;
    float f = fract(scaled);
    float fl = floor(scaled);
    float cl = ceil(scaled);
    FragColor = vec4(f, fl / 5.0, cl / 5.0, 1.0);
}
