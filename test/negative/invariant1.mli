type t = { a : int }
(*@ invariant a >= 0 *)

(* {gospel_expected|
   [125] File "invariant1.mli", line 1, characters 0-54:
         Error: Invariant on public type `t'.
   |gospel_expected} *)
