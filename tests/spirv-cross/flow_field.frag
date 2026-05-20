#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Flow field visualization
    float t = gl_FragCoord.x * 0.001;
    float angle = sin(uv.x * 2.0 + t) * cos(uv.y * 2.0 + t * 0.7) * 3.14;
    vec2 dir = vec2(cos(angle), sin(angle));
    float flow = sin(dot(uv + dir * 5.0, vec2(1.0, 0.5))) * 0.5 + 0.5;
    vec3 col = mix(vec3(0.1, 0.2, 0.4), vec3(0.3, 0.7, 0.9), flow);
    fragColor = vec4(col, 1.0);
}
