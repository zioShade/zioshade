#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Wigner function (quantum phase space)
    float x = uv.x;
    float p = uv.y;
    // Gaussian wave packet
    float psi_sq = exp(-x * x * 4.0);
    // Wigner quasi-probability distribution
    float wigner = psi_sq * cos(p * x * 8.0);
    // Blue = positive, red = negative
    vec3 col = vec3(0.0);
    col += vec3(0.2, 0.4, 0.9) * max(wigner, 0.0);
    col += vec3(0.9, 0.2, 0.2) * max(-wigner, 0.0);
    col *= smoothstep(1.0, 0.5, length(uv));
    fragColor = vec4(col, 1.0);
}
