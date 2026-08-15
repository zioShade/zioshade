
    @group(0) @binding(1) var<uniform> a : vec4f;
    @group(1) @binding(1) var<uniform> b : vec4f;

    @fragment
    fn main1() {
      _ = a;
      
      _ = b;
    }
