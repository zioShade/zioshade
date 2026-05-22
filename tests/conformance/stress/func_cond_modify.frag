// Tests: vec4 initialized from function call, then conditionally modified
precision mediump float;
uniform vec2 u_resolution;

vec4 sampleGradient(float t) {
    return vec4(t, t * t, sqrt(t), 1.0);
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 col = sampleGradient(uv.x);
    
    if (uv.y > 0.5) {
        col.r *= 0.5;
        col.g += 0.2;
    } else {
        col.b *= 2.0;
    }
    
    // Post-conditional compound assignment
    col.rgb *= 0.8 + 0.2 * sin(uv.y * 3.14159);
    
    gl_FragColor = clamp(col, 0.0, 1.0);
}
