// Tests: simple ray marching pattern
#version 450
layout(location = 0) out vec4 fragColor;
uniform vec2 u_resolution;

float scene(vec3 p) {
    return length(p) - 1.0;
}

void main() {
    vec2 uv = (gl_FragCoord.xy / u_resolution - 0.5) * 2.0;
    vec3 ro = vec3(0.0, 0.0, 3.0);
    vec3 rd = normalize(vec3(uv, -1.0));

    float t = 0.0;
    for (int i = 0; i < 50; i++) {
        float d = scene(ro + rd * t);
        if (d < 0.001) break;
        t += d;
        if (t > 10.0) break;
    }

    vec3 color = t < 10.0 ? vec3(1.0 - t * 0.1) : vec3(0.1, 0.1, 0.2);
    fragColor = vec4(color, 1.0);
}
