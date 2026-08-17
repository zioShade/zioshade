
enable f16;
@fragment
fn main() {
  var src : vec2u;
  let dst = bitcast<vec4h>(src);
}
