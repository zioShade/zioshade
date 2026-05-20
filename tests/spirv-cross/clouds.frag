#version 310 es
precision highp float;
out vec4 fragColor;

void main() {
    vec2 uv = (gl_FragCoord.xy - 150.0) / 150.0;
    // Cloud / fog layer
    float n1 = sin(uv.x * 5.0 + sin(uv.y * 3.0) * 2.0);
    float n2 = cos(uv.y * 4.0 + cos(uv.x * 3.0) * 1.5);
    float n3 = sin((uv.x + uv.y) * 7.0);
    float cloud = (n1 + n2 + n3) * 0.2 + 0.5;
    cloud = max(cloud, 0.0);
    cloud = pow(cloud, 2.0);
    vec3 sky = vec3(0.3, 0.5, 0.9);
    vec3 white = vec3(1.0);
    vec3 col = mix(sky, white, cloud);
    fragColor = vec4(col, 1.0);
}
