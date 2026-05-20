#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Schlieren / flow visualization
    float n1 = sin(uv.x * 15.0 + sin(uv.y * 3.0) * 3.0);
    float n2 = cos(uv.y * 12.0 + cos(uv.x * 4.0) * 2.0);
    float grad = dFdx(n1 + n2) * 30.0;
    float density = abs(grad);
    density = pow(density, 0.5);
    vec3 col = vec3(density * 0.8, density * 0.4, density * 0.2);
    col *= smoothstep(1.2, 0.3, length(uv));
    fragColor = vec4(col, 1.0);
}
