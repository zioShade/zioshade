// Tests: particle system with array
#version 450
uniform float u_time;

void main() {
    float positions[4];
    float velocities[4];
    for (int i = 0; i < 4; i++) {
        positions[i] = float(i) * 0.25 + u_time;
        velocities[i] = sin(u_time + float(i));
    }
    float total = 0.0;
    for (int i = 0; i < 4; i++) {
        total += positions[i] * velocities[i];
    }
    gl_FragColor = vec4(total * 0.25, 0.0, 0.0, 1.0);
}
