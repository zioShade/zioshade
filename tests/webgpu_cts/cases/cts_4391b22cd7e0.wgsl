struct A {
      @align(128) a : i32,
      }

      @fragment
      fn main() -> @location(0) vec4<f32> {
        return vec4(1., 1., 1., 1.);
      }
