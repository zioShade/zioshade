
    diagnostic(error, derivative_uniformity);
    
@group(0) @binding(0) var t : texture_1d<f32>;
@group(0) @binding(1) var s : sampler;
var<private> non_uniform_cond : bool;
var<private> non_uniform_coord : f32;
var<private> non_uniform_val : u32;
@fragment fn main() {
  
      @diagnostic(off, derivative_uniformity)
      if non_uniform_cond {
        _ = textureSample(t,s,0.0);
      }
}
;
    
