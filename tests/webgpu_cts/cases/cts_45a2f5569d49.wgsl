
enable f16;
@fragment
fn main() {
  var src : vec2i;
  let dst = bitcast<vec4<f16>>(src);
}
