// Tests: inout parameter modified in conditional branch inside loop
precision mediump float;
uniform vec2 u_resolution;

void modifyColor(inout vec3 col, float factor) {
    if (factor > 0.5) {
        col.r += factor;
        col.g += factor * 0.5;
    } else {
        col.b += factor;
    }
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    vec3 col = vec3(0.2);
    
    for (int i = 0; i < 4; i++) {
        float f = float(i) * 0.25 + uv.x * 0.1;
        modifyColor(col, f);
    }
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
