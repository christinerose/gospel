val f : int -> int
(*@ y = f x
    requires 0i = 100000000000000000000000000000000000000000000000000000000000000000000i *)

(* {gospel_expected|
   [125] File "invalid_literal.mli", line 3, characters 18-88:
         Error: Invalid int literal: `100000000000000000000000000000000000000000000000000000000000000000000i'.
   |gospel_expected} *)
