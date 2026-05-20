#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Fire/flame effect
    float n = sin(uv.x * 10.0 + uv.y * 8.0) * sin(uv.y * 6.0 - uv.x * 3.0);
    n += sin(uv.x * 20.0 - uv.y * 15.0) * 0.5;
    n = n * 0.5 + 0.5;
    float shape = 1.0 - smoothstep(-0.2, 0.6, uv.y);
    shape *= smoothstep(-0.8, -0.2, uv.y);
    shape *= smoothstep(0.8, 0.0, abs(uv.x));
    float flame = n * shape;
    vec3 col = mix(vec3(0.0), vec3(1.0, 0.8, 0.0), flame);
    col = mix(col, vec3(1.0, 0.3, 0.0), flame * uv.y * 2.0);
    fragColor = vec4(col, 1.0);
}
