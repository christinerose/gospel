
open Utils
open Oparsetree
open Uast
open Uast_utils

let gospel = "gospel"

let has_prefix ~prefix:p s =
  let l = String.length p in
  String.length s >= l && String.sub s 0 l = p

let is_spec attr = has_prefix gospel attr.attr_name.txt
let is_type_spec = function | Stype _ -> true | _ -> false
let is_val_spec  = function | Sval _  -> true | _ -> false
let is_func_spec = function | Sfunc_spec _ -> true | _ -> false

let get_attr_content attr = match attr.attr_payload with
  | PGospel s -> s, attr.attr_loc | _ -> assert false

let get_type_spec = function
  | Stype (x,_) -> x | _ -> assert false

let get_val_spec = function
  | Sval (x,_) -> x | _ -> assert false

let get_func_spec = function
  | Sfunc_spec (s,_) -> s | _ -> assert false

let split_attr attrs = List.partition is_spec attrs

(** An iterator to check if there are attributes that are GOSPEL
   specification. A warning is printed for each one that is found. *)
let unsupported_gospel =
  let gospel_attribute it at = if is_spec at then
    let loc = at.attr_loc in
    let msg = "Specification not supported" in
    let fmt = !Location.formatter_for_warnings in
    Format.fprintf fmt "@[%a@\n@{<warning>Warning:@} %s@]@."
      Location.print_loc loc msg
  in {Oast_iterator.default_iterator with attribute=gospel_attribute}

let uns_gospel = unsupported_gospel

exception Syntax_error of Location.t
exception Floating_not_allowed of Location.t
exception Orphan_decl_spec of Location.t

let () =
  Location.register_error_of_exn (function
      | Syntax_error loc ->
         Some (Location.errorf ~loc "syntax error")
      | Floating_not_allowed loc ->
         Some (Location.errorf ~loc "floating specification not allowed")
      | Orphan_decl_spec loc ->
         Some (Location.errorf ~loc "orphan specification")
      | _ -> None )

(** Parses the attribute content using the specification
   parser. Raises Syntax_error if syntax errors are found, and
   Ghost_decl if a signature starts with VAL or TYPE: in this case,
   the OCaml parser should be used to parse the signature. *)
let parse_gospel attr =
  let spec,loc = get_attr_content attr in
  let lb = Lexing.from_string spec in
  let open Location in
  let open Lexing in
  init lb loc.loc_start.pos_fname;
  lb.lex_curr_p  <- loc.loc_start;
  lb.lex_abs_pos <- loc.loc_start.pos_cnum;
  try Uparser.spec_init Ulexer.token lb with
    Uparser.Error -> begin
      let loc_start,loc_end = lb.lex_start_p, lb.lex_curr_p in
      let loc = Location.{loc_start; loc_end; loc_ghost=false}  in
      raise (Syntax_error loc) end

(** Calls the OCaml interface parser on the content of the
   attribute. It fails if the OCaml parser parses something that is
   not a type or a val. *)
let ghost_spec attr =
  let spec,loc = get_attr_content attr in
  let lb = Lexing.from_string spec in
  let open Location in
  let open Lexing in
  init lb loc.loc_start.pos_fname;
  lb.lex_curr_p <- loc.loc_start;
  lb.lex_abs_pos <- loc.loc_start.pos_cnum;
  let sign =
    try Oparser.interface Olexer.token lb with
      Oparser.Error -> begin
        let loc_start,loc_end = lb.lex_start_p, lb.lex_curr_p in
        let loc = Location.{loc_start; loc_end; loc_ghost=false}  in
        raise (Syntax_error loc) end in
  match sign with
  | [{psig_desc = (Psig_type (r,td));psig_loc}] ->
     Stype_ghost (r,td,psig_loc)
  | [{psig_desc = (Psig_value vd);psig_loc}] ->
     Sval_ghost (vd,psig_loc)
  | _  (* should not happen *)               -> assert false


(** Tries to apply the specification parser and if the parser raises a
   Ghost_decl exception, it tries the OCaml interface parser *)
let attr2spec a = try parse_gospel a with
                  | Ghost_decl -> ghost_spec a

(** It parses the attributes attached to a type declaration and
   returns a new type declaration with a specification and also the
   part of the specification that could not be attached to the type
   declaration (they are probably floating specification). If
   [extra_spec] is provided they are merged with the declaration
   specification. *)
let type_spec ?(extra_spec=[]) t =
  (* no specification attached to unsupported fields *)
  List.iter (fun (c,_)     -> uns_gospel.typ uns_gospel c) t.ptype_params;
  List.iter (fun (c1,c2,_) -> uns_gospel.typ uns_gospel c1;
                              uns_gospel.typ uns_gospel c2) t.ptype_cstrs;
  uns_gospel.type_kind uns_gospel t.ptype_kind;
  (match t.ptype_manifest with
     None -> ()
   | Some m -> uns_gospel.typ uns_gospel m);

  let spec,attr = split_attr t.ptype_attributes in
  let spec = List.map attr2spec spec in

  let tspec,fspec = Utils.split_at_f is_type_spec spec in
  let tspec = List.map get_type_spec tspec in
  let tspec = tspec @ extra_spec in
  let tspec = List.fold_left tspec_union empty_tspec tspec in
  let td = { tname = t.ptype_name;       tparams= t.ptype_params;
             tcstrs = t.ptype_cstrs;     tkind = t.ptype_kind;
             tprivate = t.ptype_private; tmanifest = t.ptype_manifest;
             tattributes = attr;         tspec = tspec;
             tloc = t.ptype_loc;} in
  td, fspec

(** It parses a list of type declarations. If more than one item is
   presented only the last one can have attributes that correspond to
   floating specification. [extra_spec], if provided, is appended to
   the last type declaration specification. Raises
   Floating_not_allowed if floating specification is found in the
   middle of recursive type declaration;*)
let type_declaration ?(extra_spec=[]) t =
  (* when we have a recursive type, we only allow floating spec
     attributes in the last element *)
  let rec get_tspecs = function
  | [] -> [],[]
  | [t] ->
     let td,fspec = type_spec ~extra_spec t in
     [td],fspec
  | t::ts ->
     let td,fspec = type_spec t in
     if fspec != [] then raise (Floating_not_allowed t.ptype_loc);
     let tds,fspec = get_tspecs ts in
     td::tds,fspec in
  let td,fspec = get_tspecs t in
  td, fspec

(** It parses the attributes of a val description. Only the first
   attribute is taken into account for the val specification. All
   other are assumed to be floating specification. *)
let val_description v =
  (* no specification attached to unsupported fields *)
  uns_gospel.typ uns_gospel v.pval_type;

  let spec,attrs =  split_attr v.pval_attributes in
  let spec = List.map attr2spec spec in

  let vd =
    { vname = v.pval_name; vtype = v.pval_type; vprim = v.pval_prim;
      vattributes = attrs; vspec = None;        vloc = v.pval_loc;} in

  match spec with
  | [] -> vd, spec
  | x::xs when is_val_spec x ->
     { vd with vspec = Some (get_val_spec x)}, xs
  | xs -> vd, xs

(** It parses floating attributes for specification. If nested
   specification is found in type/val declarations they must be
   type/val specification.

   Raises (1) Floating_not_allowed if nested specification is a
   floating specification; (2) Orphan_decl_spec if floating
   specification is a type declaration or val description*)
let rec floating_specs = function
  | [] -> []
  | Suse (q,sloc) :: xs ->
     {sdesc=Sig_use q; sloc} :: floating_specs xs
  | Sfunction (f,sloc) :: xs ->
     (* Look forward and get floating function specification *)
     let (fun_specs,xs) = split_at_f is_func_spec xs in
     let fun_specs = List.map get_func_spec fun_specs in
     let fun_specs = List.fold_left Uast_utils.fspec_union
                     f.fun_spec fun_specs in
     let f = {f with fun_spec = fun_specs } in
     {sdesc=Sig_function f;sloc} :: floating_specs xs
  | Saxiom (a,sloc) :: xs ->
     {sdesc=Sig_axiom a;sloc} :: floating_specs xs
  | Stype_ghost (r,td,sloc) :: xs ->
     (* Look forward and get floating type specification *)
     let tspecs,xs = split_at_f is_type_spec xs in
     let extra_spec = List.map get_type_spec tspecs in
     let td,fspec = type_declaration ~extra_spec td in
     (* if there is nested specification they must refer to the ghost type *)
     if fspec != [] then
       raise (Floating_not_allowed sloc);
     let sdesc = Sig_ghost_type (r,td) in
     {sdesc;sloc} :: floating_specs xs
  | Sval_ghost (vd,sloc) :: xs ->
     let vd,fspec = val_description vd in
     (* if there is nested specification they must refer to the ghost val *)
     if fspec != [] then
       raise (Floating_not_allowed sloc);
     let vd,xs =
       if vd.vspec = None then
         (* val spec might be in the subsequent floating specs *)
         match xs with
         | Sval (vs,_) :: xs -> {vd with vspec=Some vs}, xs
         | _ -> vd, xs
       else (* this val already contains a spec *)
         vd, xs in

     let sdesc = Sig_ghost_val vd in
     {sdesc;sloc} :: floating_specs xs
  | Stype (_,loc) :: _ -> raise (Orphan_decl_spec loc)
  | Sval (_,loc)  :: _ -> raise (Orphan_decl_spec loc)
  | Sfunc_spec (_,loc) :: _ -> raise (Orphan_decl_spec loc)

(** Raises warning if specifications are found in inner attributes and
   simply creates a s_with_constraint. *)
let with_constraint c =
  uns_gospel.with_constraint uns_gospel c;

  let no_spec_type_decl t =
    { tname = t.ptype_name; tparams = t.ptype_params;
      tcstrs = t.ptype_cstrs; tkind = t.ptype_kind;
      tprivate = t.ptype_private; tmanifest = t.ptype_manifest;
      tattributes = t.ptype_attributes;
      tspec = empty_tspec; tloc = t.ptype_loc;}
  in match c with
  | Pwith_type (l,t) -> Wtype (l,no_spec_type_decl t)
  | Pwith_module (l1,l2) -> Wmodule (l1,l2)
  | Pwith_typesubst (l,t) -> Wtype (l,no_spec_type_decl t)
  | Pwith_modsubst (l1,l2) -> Wmodsubst (l1,l2)

(** Translats OCaml signatures with specification attached to
   attributes into our intermediate representation. Beaware,
   prev_floats must be reverted before used *)
let rec signature_ sigs acc prev_floats = match sigs with
  | [] -> acc @ floating_specs (List.rev prev_floats)
  | {psig_desc=Psig_attribute a;
     psig_loc=sloc} :: xs  when (is_spec a) ->
     (* in this special case, we put together all the floating specs
        and only when seing another signature convert them into
        specification *)
     signature_ xs acc (attr2spec a :: prev_floats)
  | {psig_desc;psig_loc=sloc} :: xs ->
     let prev_specs = floating_specs (List.rev prev_floats) in
     let current_specs = match psig_desc with
       | Psig_value v ->
          let vd,fspec = val_description v in
          let current = [{sdesc=Sig_val vd;sloc}] in
          let attached = floating_specs fspec in
          current @ attached
       | Psig_type (r,t) ->
          let td,fspec = type_declaration t in
          let current = [{sdesc=Sig_type (r,td);sloc}] in
          let attached = floating_specs fspec in
          current @ attached
       | Psig_attribute a ->
          [{sdesc=Sig_attribute a;sloc}]
       | Psig_module m ->
          [{sdesc=Sig_module (module_declaration m);sloc}]
       | Psig_recmodule d ->
          [{sdesc=Sig_recmodule (List.map module_declaration d);sloc}]
       | Psig_modtype d ->
          [{sdesc=Sig_modtype (module_type_declaration d);sloc}]
       | Psig_typext t ->
          uns_gospel.type_extension uns_gospel t;
          [{sdesc=Sig_typext t;sloc}]
       | Psig_exception e ->
          uns_gospel.type_exception  uns_gospel e;
          [{sdesc=Sig_exception e;sloc}]
       | Psig_open o ->
          uns_gospel.open_description uns_gospel o;
          [{sdesc=Sig_open o;sloc}]
       | Psig_include i ->
          uns_gospel.include_description uns_gospel i;
          [{sdesc=Sig_include i;sloc}]
       | Psig_class c ->
          List.iter (uns_gospel.class_description uns_gospel) c;
          [{sdesc=Sig_class c;sloc}]
       | Psig_class_type c ->
          List.iter (uns_gospel.class_type_declaration uns_gospel) c;
          [{sdesc=Sig_class_type c;sloc}]
       | Psig_extension (e,a) ->
          uns_gospel.extension uns_gospel e; uns_gospel.attributes uns_gospel a;
          [{sdesc=Sig_extension (e,a);sloc}] in
     let all_specs = acc @ prev_specs @ current_specs in
     signature_ xs all_specs []

and signature sigs = signature_ sigs [] []

and module_type_desc m =
  match m with
  | Pmty_ident id ->
     Mod_ident id
  | Pmty_signature s ->
     Mod_signature (signature s)
  | Pmty_functor (l,m1,m2) ->
     Mod_functor (l,Utils.opmap module_type m1, module_type m2)
  | Pmty_with (m,c) ->
     Mod_with (module_type m, List.map with_constraint c)
  | Pmty_typeof m ->
     uns_gospel.module_expr uns_gospel m; Mod_typeof m
  | Pmty_extension e -> Mod_extension e
  | Pmty_alias a -> Mod_alias a

and module_type m =
  uns_gospel.attributes uns_gospel m.pmty_attributes;
  { mdesc = module_type_desc m.pmty_desc;
    mloc = m.pmty_loc; mattributes = m.pmty_attributes}

and module_declaration m =
  uns_gospel.attributes uns_gospel m.pmd_attributes;
  { mdname = m.pmd_name; mdtype = module_type m.pmd_type;
    mdattributes = m.pmd_attributes; mdloc = m.pmd_loc }

and module_type_declaration m =
  uns_gospel.attributes uns_gospel m.pmtd_attributes;
  { mtdname = m.pmtd_name; mtdtype = Utils.opmap module_type m.pmtd_type;
    mtdattributes = m.pmtd_attributes; mtdloc = m.pmtd_loc}