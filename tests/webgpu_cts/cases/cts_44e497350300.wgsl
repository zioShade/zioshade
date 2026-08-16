
      @fragment
      fn main() {
        var v: vec3<i32> = vec3(1, 2, 3);
        var w: vec4<i32> = vec4(10);
        v *= w.xyz;
      }
    
