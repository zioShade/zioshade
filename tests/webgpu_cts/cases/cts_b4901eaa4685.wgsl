
    struct VertexOut {
      @builtin(position) @
invariant position : vec4<f32>
    };
    @vertex
    fn main() -> VertexOut {
      return VertexOut();
    }
    
