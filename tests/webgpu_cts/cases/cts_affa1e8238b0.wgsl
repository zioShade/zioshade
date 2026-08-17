
enable f16;
@fragment
fn main() {
  var src : vec2<u32>;
  let dst = bitcast<vec4h>(src);
}
