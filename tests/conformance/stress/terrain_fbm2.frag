// Tests: fbm (fractal Brownian motion) with function chain
// Previously broken: OpSwitch DCE corruption with function calls in case bodies
precision mediump float;
uniform vec2 u_resolution;

float hash(float n) {
    return fract(sin(n) * 43758.5453);
}

float noise(float x) {
    float i = floor(x);
    float f = fract(x);
    float t = f * f * (3.0 - 2.0 * f);
    return mix(hash(i), hash(i + 1.0), t);
}

float fbm(float x) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += amp * noise(x);
        x *= 2.0;
        amp *= 0.5;
    }
    return val;
}

void main() {
    vec2 uv = gl_FragCoord.xy / u_resolution;
    
    float n1 = fbm(uv.x * 5.0);
    float n2 = fbm(uv.y * 3.0 + 100.0);
    
    float height = n1 * 0.6 + n2 * 0.4;
    
    // Color based on height
    vec3 col;
    if (height < 0.3) {
        col = vec3(0.2, 0.3, 0.5); // water
    } else if (height < 0.5) {
        col = vec3(0.3, 0.6, 0.2); // grass
    } else if (height < 0.7) {
        col = vec3(0.5, 0.4, 0.2); // dirt
    } else {
        col = vec3(0.9, 0.9, 0.95); // snow
    }
    
    gl_FragColor = vec4(col, 1.0);
}
