
      

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat2x2(0, 1, 2, 3));
      }
