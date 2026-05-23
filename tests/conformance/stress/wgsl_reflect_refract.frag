#version 450
uniform vec2 u_resolution;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    // reflect, refract
    vec2 incident = uv - vec2(0.5);
    vec2 normal = vec2(0.0, 1.0);
    vec2 r = reflect(incident, normal);
    vec2 t = refract(incident, normal, 0.5);
    fragColor = vec4(r.x + 0.5, r.y + 0.5, t.x + 0.5, 1.0);
}
