
enable f16;
@fragment
fn main() {
  var src : vec2<f16>;
  let dst = bitcast<i32>(src);
}
