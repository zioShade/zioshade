
@vertex fn main(@interpolate(flat,) @location(0) b: f32) ->
    @builtin(position) vec4<f32> {
  return vec4f(0);
}
