#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    float r = length(uv);
    float a = atan(uv.y, uv.x);
    
    // Gear teeth pattern
    float teeth = 12.0;
    float tooth_profile = cos(a * teeth) * 0.05;
    float inner_r = 0.3 + tooth_profile;
    float outer_r = 0.5 + tooth_profile;
    
    float gear1 = smoothstep(inner_r, inner_r + 0.01, r) * (1.0 - smoothstep(outer_r, outer_r + 0.01, r));
    float center_hole = 1.0 - smoothstep(0.1, 0.12, r);
    
    vec3 col = vec3(0.6, 0.6, 0.65) * gear1;
    col = mix(col, vec3(0.1), center_hole);
    col = mix(vec3(0.15), col, gear1);
    fragColor = vec4(col, 1.0);
}
