
      

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat2x2(0f, 1f, 2f, 3f));
      }
