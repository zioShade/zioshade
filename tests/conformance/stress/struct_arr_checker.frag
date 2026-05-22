// Tests: struct member that is an array, accessed inside a conditional loop
precision mediump float;
uniform vec2 u_resolution;

struct Pattern {
    vec3 palette[3];
    float scale;
};

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    Pattern p;
    p.palette[0] = vec3(1.0, 0.3, 0.1);
    p.palette[1] = vec3(0.1, 1.0, 0.3);
    p.palette[2] = vec3(0.3, 0.1, 1.0);
    p.scale = 5.0;
    
    vec2 scaled = uv * p.scale;
    float checker = mod(floor(scaled.x) + floor(scaled.y), 3.0);
    int idx = int(checker);
    
    // Dynamic index into struct array member
    vec3 col = p.palette[idx];
    
    // Add distance-based fade
    float d = length(uv - 0.5);
    col *= 1.0 - d * 0.5;
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
