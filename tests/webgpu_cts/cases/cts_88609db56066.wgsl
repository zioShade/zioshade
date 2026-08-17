
enable f16;
@fragment
fn main() {
  var src : vec2<f32>;
  let dst = bitcast<vec4<f16>>(src);
}
