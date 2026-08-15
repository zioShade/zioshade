alias f32_alias = f32;

          @group(0) @binding(0) var s: sampler;
          @group(0) @binding(1) var t: texture_2d<f32>;

          var<workgroup> a: atomic<u32>;

          struct A {
            i: f32,
          }
          struct B {
            arry: array<f32>,
          }
          @group(0) @binding(3) var<storage> k: B;


          @vertex
          fn main() -> @builtin(position) vec4<f32> {
            
            _ = modf(f32_alias(1.f));
            return vec4<f32>(.4, .2, .3, .1);
          }
