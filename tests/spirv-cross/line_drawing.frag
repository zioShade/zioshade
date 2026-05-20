#version 310 es
precision highp float;
out vec4 fragColor;

float sdLine(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

void main() {
    vec2 uv = gl_FragCoord.xy;
    float d1 = sdLine(uv, vec2(50.0, 50.0), vec2(250.0, 200.0));
    float d2 = sdLine(uv, vec2(100.0, 250.0), vec2(200.0, 50.0));
    float d = min(d1, d2);
    float line = smoothstep(2.0, 0.0, d);
    fragColor = vec4(vec3(line), 1.0);
}
