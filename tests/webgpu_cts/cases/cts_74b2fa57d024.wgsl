
      

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat2x2(0.0, 1.0, 2.0, 3.0));
      }
