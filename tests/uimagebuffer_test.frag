#version 450
layout(binding = 0, r32ui) uniform uimageBuffer data;
void main()
{
    imageAtomicAdd(data, 0, 0);
}
