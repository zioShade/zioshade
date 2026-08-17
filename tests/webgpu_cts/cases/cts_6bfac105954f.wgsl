
enable f16;
@fragment
fn main() {
  var src : vec4h;
  let dst = bitcast<vec2<u32>>(src);
}
