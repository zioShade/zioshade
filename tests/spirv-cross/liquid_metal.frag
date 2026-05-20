#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Liquid metal / mercury surface
    float n1 = sin(uv.x * 12.0 + uv.y * 8.0) * cos(uv.y * 10.0 - uv.x * 6.0);
    float n2 = cos(uv.x * 15.0 - uv.y * 12.0) * sin(uv.y * 7.0 + uv.x * 9.0);
    float normal = (n1 + n2) * 0.25 + 0.5;
    // Fake environment reflection
    vec3 ref = vec3(normal * 0.8 + 0.1);
    ref = pow(ref, vec3(3.0)) * 2.0;
    // Edge highlight
    float edge = 1.0 - smoothstep(0.7, 0.9, length(uv));
    vec3 col = ref * edge;
    fragColor = vec4(col, 1.0);
}
