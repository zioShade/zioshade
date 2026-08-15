
enable f16;
@fragment
fn main() {
  var src : vec2h;
  let dst = bitcast<u32>(src);
}
