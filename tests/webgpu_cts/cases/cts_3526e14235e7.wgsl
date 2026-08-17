
enable f16;
@fragment
fn main() {
  var src : vec2<f16>;
  let dst = bitcast<f32>(src);
}
