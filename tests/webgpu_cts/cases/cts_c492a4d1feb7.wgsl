
enable f16;
@fragment
fn main() {
  var src : vec2f;
  let dst = bitcast<vec4h>(src);
}
