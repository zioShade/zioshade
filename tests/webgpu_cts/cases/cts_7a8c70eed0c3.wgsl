
enable f16;
@fragment
fn main() {
  var src : u32;
  let dst = bitcast<vec2<f16>>(src);
}
