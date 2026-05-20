#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Chess board with perspective
    float scale = 4.0;
    vec2 p = uv * scale;
    float checker = mod(floor(p.x) + floor(p.y), 2.0);
    // Distance fog
    float dist = length(uv);
    float fog = 1.0 - smoothstep(0.3, 1.0, dist);
    vec3 white = vec3(0.9);
    vec3 black = vec3(0.2);
    vec3 col = mix(white, black, checker) * fog + vec3(0.05) * (1.0 - fog);
    fragColor = vec4(col, 1.0);
}
