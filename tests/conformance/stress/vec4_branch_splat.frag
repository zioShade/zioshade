// Tests: vec4 constructed from mixed scalar/vector expressions in branches
precision mediump float;
uniform vec2 u_resolution;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    vec4 col;
    
    if (uv.x > 0.5) {
        float r = sin(uv.x * 6.28) * 0.5 + 0.5;
        col = vec4(r, uv.y, 1.0 - r, 1.0);
    } else {
        vec2 center = uv - 0.5;
        float d = length(center);
        col = vec4(d, d * 2.0, d * 3.0, 1.0);
    }
    
    // Post-branch swizzle modify
    col.rgb *= 0.8 + 0.2 * cos(uv.xyx * 3.14);
    
    gl_FragColor = clamp(col, 0.0, 1.0);
}
