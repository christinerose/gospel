type tc = char * int
(*@ function f (a : tc) : bool =
      match a with
      | '\000'..'b', 0i -> true
      | 'b'..'\255', x -> false
*)

(* {gospel_expected|
   [125] File "tuple2.mli", line 3, characters 6-82:
         Error: This pattern-matching is not exhaustive.
                Here is an example of a case that is not matched:
                  '\000', 1i.
   |gospel_expected} *)
