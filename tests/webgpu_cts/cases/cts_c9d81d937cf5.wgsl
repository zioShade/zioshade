
enable f16;
@fragment
fn main() {
  var src : i32;
  let dst = bitcast<vec2<f16>>(src);
}
