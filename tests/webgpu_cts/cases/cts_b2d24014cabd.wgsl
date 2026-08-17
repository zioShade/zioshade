
      

      @compute @workgroup_size(1)
      fn main() {
        const c = determinant(mat4x4(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
      }
