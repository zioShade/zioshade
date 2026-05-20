#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Morph between circle and star
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    float points = 5.0;
    float morph = uv.x * 0.5 + 0.5;
    // Circle distance
    float circle_d = r - 0.5;
    // Star distance
    float star_angle = cos(points * a);
    float star_r = 0.3 + 0.2 * max(star_angle, 0.0);
    float star_d = r - star_r;
    // Morph
    float d = mix(circle_d, star_d, morph);
    float shape = smoothstep(0.02, -0.02, d);
    vec3 col = vec3(0.1) + vec3(0.8, 0.6, 0.2) * shape;
    fragColor = vec4(col, 1.0);
}
