#version 450
float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
    vec2 i = floor(p); vec2 f = fract(p); f = f*f*(3.0-2.0*f);
    return mix(mix(hash(i), hash(i+vec2(1,0)), f.x), mix(hash(i+vec2(0,1)), hash(i+vec2(1,1)), f.x), f.y);
}
void main() {
    vec2 uv = gl_FragCoord.xy / vec2(128.0);
    float n = noise(uv * 4.0) * 0.6 + noise(uv * 8.0) * 0.3 + noise(uv * 16.0) * 0.1;
    vec3 sky = mix(vec3(0.4, 0.6, 0.9), vec3(1.0), smoothstep(0.4, 0.7, n));
    gl_FragColor = vec4(sky, 1.0);
}
