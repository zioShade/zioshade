
      
      var<private> priv_var : i32;

      
      @group(0) @binding(0)
      var<storage> stor_var : i32;

      struct A {
        
        a : i32,
      }

      @vertex
      
      fn f(
        
        @location(0) b : i32,
      ) ->  @builtin(position) vec4f {
        
        var<function> func_v : i32;

        
        while false {}

        return vec4(1, 1, 1, 1);
      }
    
