
    struct VertexOut {
      @builtin(position) @/* comment */invariant position : vec4<f32>
    };
    @vertex
    fn main() -> VertexOut {
      return VertexOut();
    }
    
