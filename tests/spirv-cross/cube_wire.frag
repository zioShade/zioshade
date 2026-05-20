#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // 3D cube wireframe projection
    vec3 p = vec3(uv * 1.5, -2.0);
    float rot = 0.5;
    vec3 c1 = vec3(cos(rot), sin(rot), 0.0);
    vec3 c2 = vec3(-sin(rot), cos(rot), 0.0);
    
    // Isometric cube
    vec3 n = vec3(0.0, 0.0, 1.0);
    float s = 0.5;
    vec3 v1 = vec3(s, s, s);
    vec3 v2 = vec3(-s, s, s);
    vec3 v3 = vec3(-s, -s, s);
    vec3 v4 = vec3(s, -s, s);
    vec3 v5 = vec3(s, s, -s);
    
    // Simple projection
    vec2 p1 = v1.xy - p.xy;
    vec2 p2 = v2.xy - p.xy;
    vec2 p3 = v3.xy - p.xy;
    
    float d1 = length(p1);
    float d2 = length(p2);
    float d3 = length(p3);
    
    float min_d = min(d1, min(d2, d3));
    float wire = smoothstep(0.1, 0.08, min_d);
    fragColor = vec4(vec3(wire), 1.0);
}
