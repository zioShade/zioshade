diagnostic(off, derivative_uniformity);



@group(0) @binding(0)
var<storage> uniform_value : array<vec3u, 4>;
@group(0) @binding(1)
var<storage, read_write> nonuniform_value : array<vec3u, 4>;

@group(1) @binding(0)
var t : texture_2d<f32>;
@group(1) @binding(1)
var s : sampler;

var<private> nonuniform_cond : bool = true;
const uniform_cond : bool = true;
var<private> nonuniform_val : u32 = 0;
const uniform_val : u32 = 0;

@fragment
fn main() {
  var x : vec3u = uniform_value[3];;

  x.x = nonuniform_value[0].x;
    x.y = uniform_value[0].y;
    x.z = uniform_value[0].z;

  if x.x > 0 {
    let tmp = textureSample(t, s, vec2f(0,0));
  }
}
