#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy * 0.005;
    // Chain link fence
    float scale = 4.0;
    vec2 p = uv * scale;
    vec2 cell = floor(p);
    vec2 f = fract(p);
    // Diagonal wires
    float diag1 = abs(f.x - f.y);
    float diag2 = abs(f.x + f.y - 1.0);
    float wire1 = smoothstep(0.06, 0.03, diag1);
    float wire2 = smoothstep(0.06, 0.03, diag2);
    // Over-under at crossings
    float checker = mod(cell.x + cell.y, 2.0);
    float wire = max(wire1 * (checker + wire2 * 0.5), wire2 * ((1.0 - checker) + wire1 * 0.5));
    wire = min(wire, 1.0);
    vec3 bg = vec3(0.4, 0.6, 0.3);
    vec3 metal = vec3(0.6, 0.6, 0.6);
    vec3 col = mix(bg, metal, wire);
    fragColor = vec4(col, 1.0);
}
