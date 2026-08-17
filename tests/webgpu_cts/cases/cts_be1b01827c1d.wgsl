
      

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat3x3(0, 1, 2, 3, 4, 5, 6, 7, 8));
      }
