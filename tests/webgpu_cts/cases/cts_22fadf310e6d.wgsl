
enable f16;
@fragment
fn main() {
  var src : f32;
  let dst = bitcast<vec2<f16>>(src);
}
