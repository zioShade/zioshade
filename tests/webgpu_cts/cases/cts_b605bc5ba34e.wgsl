
@group(0) @binding(0) var t : texture_1d<f32>;
@group(0) @binding(1) var s : sampler;
var<private> non_uniform_cond : bool;
var<private> non_uniform_coord : f32;
var<private> non_uniform_val : u32;
@fragment fn main() {
  
      if non_uniform_cond {
        @diagnostic(off, derivative_uniformity)
        if textureSample(t,s,non_uniform_coord).x > 0.0
          @diagnostic(error, derivative_uniformity) {
        }
      }
}
