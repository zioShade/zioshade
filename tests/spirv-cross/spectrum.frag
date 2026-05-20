#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Electromagnetic spectrum visualization
    float wavelength = uv.x * 0.5 + 0.5; // 0=violet, 1=red
    vec3 col;
    if (wavelength < 0.17) {
        col = mix(vec3(0.4, 0.0, 0.6), vec3(0.2, 0.0, 1.0), wavelength / 0.17);
    } else if (wavelength < 0.33) {
        col = mix(vec3(0.2, 0.0, 1.0), vec3(0.0, 0.8, 0.0), (wavelength - 0.17) / 0.16);
    } else if (wavelength < 0.5) {
        col = mix(vec3(0.0, 0.8, 0.0), vec3(1.0, 1.0, 0.0), (wavelength - 0.33) / 0.17);
    } else if (wavelength < 0.67) {
        col = mix(vec3(1.0, 1.0, 0.0), vec3(1.0, 0.5, 0.0), (wavelength - 0.5) / 0.17);
    } else {
        col = mix(vec3(1.0, 0.5, 0.0), vec3(0.8, 0.0, 0.0), (wavelength - 0.67) / 0.33);
    }
    // Intensity wave
    float intensity = sin(uv.y * 15.0) * 0.3 + 0.7;
    col *= intensity;
    fragColor = vec4(col, 1.0);
}
