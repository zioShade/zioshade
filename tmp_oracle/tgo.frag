#version 450
layout(binding=0) uniform sampler2D s;
layout(location=0) out vec4 o;
void main(){
  const ivec2 offs[4]=ivec2[4](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,1));
  o = textureGatherOffsets(s, vec2(0.5), offs, 1);
}
