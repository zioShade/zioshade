#version 430

float square(float x) {
    return x * x;
}

struct Light {
    vec3 position;
    float intensity;
};

void main() {
    float x = 2.0;
    float y = square(x);

    Light light;
    light.position = vec3(1.0, 2.0, 3.0);
    light.intensity = 1.5;

    vec3 pos = light.position;
    float intensity = light.intensity;

    float arr[3];
    arr[0] = 1.0;
    arr[1] = 2.0;
    arr[2] = 3.0;

    float val = arr[1];
}
