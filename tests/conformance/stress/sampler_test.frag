// Tests: image sampling patterns (sampler2D)
precision mediump float;
uniform vec2 u_resolution;
uniform sampler2D u_texture;

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    // Basic texture sampling
    vec4 t0 = texture(u_texture, uv);
    
    // Texture with offset
    vec4 t1 = texture(u_texture, uv + vec2(0.01, 0.0));
    
    // Texture with Lod
    vec4 t2 = textureLod(u_texture, uv, 0.0);
    
    // Mix texture results
    vec3 col = mix(t0.rgb, t1.rgb, t2.r);
    
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
