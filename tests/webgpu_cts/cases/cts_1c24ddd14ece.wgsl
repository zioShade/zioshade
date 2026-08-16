
const a = 5;
const b = 6;
override z = 7;
override y = 8;

@vertex fn main(
  @location(2147483647) res: f32
) -> @builtin(position) vec4f {
  return vec4f(0);
}
