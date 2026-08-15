
  
  alias bool_alias = bool;

  @group(0) @binding(0) var s: sampler;
  @group(0) @binding(1) var t: texture_2d<f32>;

  var<workgroup> a: atomic<u32>;

  struct A {
    i: bool,
  }
  struct B {
    arry: array<u32>,
  }
  @group(0) @binding(3) var<storage> k: B;

  @vertex
  fn main() -> @builtin(position) vec4<f32> {
    var<function> a = true;
            let p: ptr<function, bool> = &a;
            _ = any(*p);
    return vec4<f32>(.4, .2, .3, .1);
  }
