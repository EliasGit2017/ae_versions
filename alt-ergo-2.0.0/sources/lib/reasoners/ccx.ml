(******************************************************************************)
(*                                                                            *)
(*     The Alt-Ergo theorem prover                                            *)
(*     Copyright (C) 2006-2013                                                *)
(*                                                                            *)
(*     Sylvain Conchon                                                        *)
(*     Evelyne Contejean                                                      *)
(*                                                                            *)
(*     Francois Bobot                                                         *)
(*     Mohamed Iguernelala                                                    *)
(*     Stephane Lescuyer                                                      *)
(*     Alain Mebsout                                                          *)
(*                                                                            *)
(*     CNRS - INRIA - Universite Paris Sud                                    *)
(*                                                                            *)
(*     This file is distributed under the terms of the Apache Software        *)
(*     License version 2.0                                                    *)
(*                                                                            *)
(*  ------------------------------------------------------------------------  *)
(*                                                                            *)
(*     Alt-Ergo: The SMT Solver For Software Verification                     *)
(*     Copyright (C) 2013-2017 --- OCamlPro SAS                               *)
(*                                                                            *)
(*     This file is distributed under the terms of the Apache Software        *)
(*     License version 2.0                                                    *)
(*                                                                            *)
(******************************************************************************)

open Format
open Options
open Sig
open Exception

module X = Combine.Shostak
module Ex = Explanation
module SetF = Formula.Set
module T = Term
module A = Literal
module LR = A.Make(struct type t = X.r let compare = X.str_cmp include X end)
module SetT = Term.Set
module Sy = Symbols

module type S = sig

  type t
  type r = Combine.Shostak.r

  val empty : unit -> t

  val empty_facts : unit -> r Sig.facts

  val add_fact : r Sig.facts -> r fact -> unit

  val add_term :
    t ->
    r Sig.facts -> (* acc *)
    Term.t ->
    Explanation.t ->
    t * r Sig.facts

  val add :
    t ->
    r Sig.facts -> (* acc *)
    Literal.LT.t ->
    Explanation.t -> t * r Sig.facts

  val assume_literals :
    t ->
    (r Sig.literal * Explanation.t * Sig.lit_origin) list ->
    r Sig.facts ->
    t * (r Sig.literal * Explanation.t * Sig.lit_origin) list

  val case_split :
    t -> for_model:bool -> (r Literal.view * bool * Sig.lit_origin) list * t
  val query :  t -> Literal.LT.t -> Sig.answer
  val new_terms : t -> Term.Set.t
  val class_of : t -> Term.t -> Term.t list
  val are_equal : t -> Term.t -> Term.t -> added_terms:bool -> Sig.answer
  val are_distinct : t -> Term.t -> Term.t -> Sig.answer
  val cl_extract : t -> Term.Set.t list
  val term_repr : t -> Term.t -> Term.t
  val print_model : Format.formatter -> t -> unit
  val get_union_find : t -> Combine.Uf.t

  val assume_th_elt : t -> Commands.th_elt -> t
  val theories_instances :
    do_syntactic_matching:bool ->
    Matching_types.info Term.Map.t * Term.t list Term.Map.t Term.Subst.t ->
    t -> (Formula.t -> Formula.t -> bool) -> t * Sig.instances

  val retrieve_used_context :
    t -> Explanation.t -> Formula.t list * Formula.t list
end

module Main : S = struct

  module SetA = Use.SA
  module Use = Combine.Use
  module Uf = Combine.Uf
  module Rel = Combine.Relation
  module Q = Queue
  module MX = Map.Make(struct type t = X.r let compare = X.hash_cmp end)

  type t = {
    use : Use.t;
    uf : Uf.t ;
    relation : Rel.t
  }

  type r = Combine.Shostak.r

  let empty () = {
    use = Use.empty ;
    uf = Uf.empty () ;
    relation = Rel.empty [];
  }

  let empty_facts () =
    { equas   = Queue.create ();
      ineqs   = Queue.create ();
      diseqs  = Queue.create ();
      touched = Util.MI.empty }

  let add_fact facts ((lit, ex, orig) as e) =
    match lit with
    | LSem Literal.Pred _ | LSem Literal.Eq _ -> Queue.push e facts.equas
    | LSem Literal.Distinct _ -> Queue.push e facts.diseqs
    | LSem Literal.Builtin _  -> Queue.push e facts.ineqs
    | LTerm a ->
      match Literal.LT.view a with
      | Literal.Pred _ | Literal.Eq _ -> Queue.push e facts.equas
      | Literal.Distinct _ -> Queue.push e facts.diseqs
      | Literal.Builtin _  -> Queue.push e facts.ineqs

  (*BISECT-IGNORE-BEGIN*)
  module Debug = struct

    let facts (f : r Sig.facts) msg =
      let aux fmt q =
        Q.iter
          (fun (lit,_,_) ->
            match lit with
            | LSem sa -> fprintf fmt "  > LSem  %a@." LR.print (LR.make sa)
            | LTerm a -> fprintf fmt "  > LTerm %a@."Literal.LT.print a
          )q
      in
      let aux2 fmt mp =
        Util.MI.iter
          (fun _ x -> fprintf fmt "%a |-> ... (See Uf)@." X.print x) mp
      in
      if debug_cc () then begin
        fprintf fmt "I am in %s with the following facts@." msg;
        fprintf fmt "---- Begin Facts -----------------------------------@.";
        fprintf fmt "Equalities:@.%a" aux f.equas;
        fprintf fmt "Disequalities:@.%a" aux f.diseqs;
        fprintf fmt "Inequalities:@.%a" aux f.ineqs;
        fprintf fmt "Touched:@.%a" aux2 f.touched;
        fprintf fmt "---- End   Facts -----------------------------------@.@.";
      end

    let cc r1 r2 =
      if debug_cc () then
	fprintf fmt "[cc] congruence closure : %a = %a@."
	  X.print r1 X.print r2

    let make_cst t ctx =
      if debug_cc () then
	if ctx != [] then
          begin
            fprintf fmt "[cc] constraints of make(%a)@." Term.print t;
            let c = ref 0 in
            List.iter
              (fun a ->
               incr c;
               fprintf fmt " %d) %a@." !c A.LT.print a) ctx
	  end

    let add_to_use t =
      if debug_cc () then
	fprintf fmt "[cc] add_to_use: %a@." T.print t

    let lrepr fmt = List.iter (fprintf fmt "%a " X.print)

    let leaves t lvs =
      fprintf fmt "[cc] leaves of %a@.@."
	T.print t; lrepr fmt lvs

    let contra_congruence a ex =
      if debug_cc () then
	fprintf fmt "[cc] find that %a %a by contra-congruence@."
	  A.LT.print a Ex.print ex

    let assume_literal sa =
      if debug_cc () then
	fprintf fmt "[cc] assume literal : %a@." LR.print (LR.make sa)

    let congruent a ex =
      if debug_cc () then
	fprintf fmt "[cc] new fact by conrgruence : %a ex[%a]@."
          A.LT.print a Ex.print ex

    let cc_result p v touched =
      if debug_cc() then begin
        fprintf fmt "[cc] the binding %a -> %a touched:@." X.print p X.print v;
        List.iter
          (fun (x, y, _) ->
            fprintf fmt "  > %a ~~ becomes ~> %a@." X.print x X.print y) touched
      end

  end
  (*BISECT-IGNORE-END*)

  let one, _ = X.make (Term.make (Sy.name "@bottom") [] Ty.Tint)

  let concat_leaves uf l =
    let rec concat_rec acc t =
      match  X.leaves (fst (Uf.find uf t)) , acc with
	  [] , _ -> one::acc
	| res, [] -> res
	| res , _ -> List.rev_append res acc
    in
    match List.fold_left concat_rec [] l with
	[] -> [one]
      | res -> res

  let are_equal env ex t1 t2 =
    if T.equal t1 t2 then ex
    else match Uf.are_equal env.uf t1 t2 ~added_terms:true with
      | Yes (dep, _) -> Ex.union ex dep
      | No -> raise Exit

  let equal_only_by_congruence env facts t1 t2 =
    if not (T.equal t1 t2) then
      let {T.f=f1; xs=xs1; ty=ty1} = T.view t1 in
      let {T.f=f2; xs=xs2; ty=ty2} = T.view t2 in
      if Symbols.equal f1 f2 && Ty.equal ty1 ty2 then
	try
          let ex = List.fold_left2 (are_equal env) Ex.empty xs1 xs2 in
          let a = A.LT.mk_eq t1 t2 in
          Debug.congruent a ex;
          Q.push (LTerm a, ex, Sig.Other) facts.equas
        with Exit -> ()

  let congruents env facts t1 s =
    match T.view t1 with
    | {T.xs=[]} -> ()
    | {T.f} when X.fully_interpreted f -> ()
    | _ -> SetT.iter (equal_only_by_congruence env facts t1) s


  let fold_find_with_explanation find ex l =
    List.fold_left
      (fun (lr, ex) t ->
	let r, ex_r = find t in r::lr, Ex.union ex_r ex)
      ([], ex) l

  let view find va ex_a =
    match va with
      | A.Pred (t1, b) ->
        let r1, ex1 = find t1 in
	let ex = Ex.union ex1 ex_a in
	LR.mkv_pred r1 b, ex
      | A.Eq (t1, t2) ->
        let r1, ex1 = find t1 in
	let r2, ex2 = find t2 in
	let ex = Ex.union (Ex.union ex1 ex2) ex_a in
	LR.mkv_eq r1 r2, ex
      | A.Distinct (b, lt) ->
	let lr, ex = fold_find_with_explanation find ex_a lt in
	LR.mkv_distinct b (List.rev lr), ex
      | A.Builtin(b, s, l) ->
	let lr, ex  = fold_find_with_explanation find ex_a l in
	LR.mkv_builtin b s (List.rev lr), ex

  let term_canonical_view env a ex_a =
    view (Uf.find env.uf) (A.LT.view a) ex_a

  let canonical_view env a ex_a = view (Uf.find_r env.uf) a ex_a

  (* Begin: new implementation of add, add_term, assume_literals and all that *)

  let new_facts_by_contra_congruence env facts r bol =
    match X.term_extract r with
    | None, _ -> ()
    | Some _, false -> () (* not an original term *)
    | Some t1, true ->  (* original term *)
      match T.view t1 with
      | {T.f=f1 ; xs=[x]} ->
        let ty_x = (Term.view x).Term.ty in
	List.iter
	  (fun t2 ->
	    match T.view t2 with
	    | {T.f=f2 ; xs=[y]} when Sy.equal f1 f2 ->
              let ty_y = (Term.view y).Term.ty in
              if Ty.equal ty_x ty_y then
		begin match Uf.are_distinct env.uf t1 t2 with
		| Yes (ex_r, _) ->
		  let a = A.LT.mk_distinct false [x; y] in
                  Debug.contra_congruence a ex_r;
		  Q.push (LTerm a, ex_r, Sig.Other) facts.diseqs
		| No -> assert false
		end
	    | _ -> ()
	  ) (Uf.class_of env.uf bol)
      | _ -> ()

  let clean_use =
    List.fold_left
      (fun env a ->
       match A.LT.view a with
       | A.Distinct (_, lt)
       | A.Builtin (_, _, lt) ->
	  let lvs = concat_leaves env.uf lt in
	  List.fold_left
	    (fun env rx ->
	     let st, sa = Use.find rx env.use in
             (* SetA does not use ex, so Ex.empty is OK for removing *)
	     let sa = SetA.remove (a, Ex.empty) sa in
	     { env with use = Use.add rx (st,sa) env.use }
	    ) env lvs
       | _ -> assert false
      )

  let contra_congruence env facts r =
    Options.exec_thread_yield ();
    if X.equal (fst (Uf.find_r env.uf r)) (X.top()) then
      new_facts_by_contra_congruence env facts r T.faux
    else if X.equal (fst (Uf.find_r env.uf r)) (X.bot()) then
      new_facts_by_contra_congruence env facts r T.vrai

  let congruence_closure env (facts:r Sig.facts) r1 r2 ex =
    Options.exec_thread_yield ();
    Debug.cc r1 r2;
    let uf, res = Uf.union env.uf r1 r2 ex in
    List.fold_left
      (fun env (p, touched, v) ->
	Options.exec_thread_yield ();
        Debug.cc_result p v touched;
        assert (X.is_a_leaf p);
	(* we look for use(p) *)
      	let p_t, p_a = Use.find p env.use in

	(* we compute terms and atoms to consider for congruence *)
	let repr_touched = List.map (fun (x, y, ex) ->
          facts.touched <- Util.MI.add (X.hash x) x facts.touched;
          y
        ) touched
        in
	let st_others, sa_others = Use.congr_close_up env.use p repr_touched in

	(* we update use *)
	let nuse = Use.up_close_up env.use p v in
        let nuse =
          List.fold_left
            (fun nuse (r, rr, ex) ->
              match X.leaves rr with
              | _ :: _ -> nuse
              | []     -> Use.up_close_up nuse p one
            )nuse touched
        in
	Use.print nuse;

	(* we check the congruence of the terms. *)
	let env =  {env with use=nuse} in
	SetT.iter (fun t -> congruents env facts t st_others) p_t;

        (*CC of preds ?*)
	SetA.iter (fun (a, ex) -> add_fact facts (LTerm a, ex, Sig.Other)) p_a;

        (*touched preds ?*)
        SetA.iter (fun (a, ex) -> add_fact facts (LTerm a, ex, Sig.Other))
          sa_others;

	env
      ) {env with uf=uf}  res

  module LRT =
    Map.Make (struct
      type t = LR.t * Literal.LT.t option
      let compare (x, y) (x', y') =
        let c = LR.compare x x' in
        if c <> 0 then c
        else match y, y' with
        | None, None      ->  0
        | Some _, None    ->  1
        | None, Some _    -> -1
        | Some a, Some a' -> Literal.LT.compare a a'
    end)

  let make_unique sa =
    let mp =
      List.fold_left
        (fun mp ((ra, aopt ,_ ,_) as e) ->
          LRT.add (LR.make ra, aopt) e mp
        ) LRT.empty sa
    in
    LRT.fold (fun _ e acc -> e::acc)mp []

  let replay_atom env sa =
    Options.exec_thread_yield ();
    let sa = make_unique sa in
    let relation, result = Rel.assume env.relation env.uf sa in
    let env = { env with relation = relation } in
    let env = clean_use env result.remove in
    env, result.assume

  let rec add_term env facts t ex =
    Options.exec_thread_yield ();
    (* nothing to do if the term already exists *)
    if Uf.mem env.uf t then env
    else begin
      Options.tool_req 3 "TR-CCX-AddTerm";
      Debug.add_to_use t;

      (* we add t's arguments in env *)
      let {T.f = f; xs = xs} = T.view t in
      let env = List.fold_left (fun env t -> add_term env facts t ex) env xs in
      (* we update uf and use *)
      let nuf, ctx  = Uf.add env.uf t in
      Debug.make_cst t ctx;
      List.iter (fun a -> add_fact facts (LTerm a, ex, Sig.Other)) ctx;
      (*or Ex.empty ?*)

      let rt, _ = Uf.find nuf t in
      let lvs = concat_leaves nuf xs in
      let nuse = Use.up_add env.use t rt lvs in

      (* If finitetest is used we add the term to the relation *)
      let rel = Rel.add env.relation nuf rt t in
      Use.print nuse;

      (* we compute terms to consider for congruence *)
      (* we do this only for non-atomic terms with uninterpreted
         head-symbol *)
      let st_uset = Use.congr_add nuse lvs in

      (* we check the congruence of each term *)
      let env = {uf = nuf; use = nuse; relation = rel} in
      congruents env facts t st_uset;
      env
    end

  let add env facts a ex =
    match A.LT.view a with
    | A.Pred (t1, _) ->
      add_term env facts t1 ex
      | A.Eq (t1, t2) ->
	let env = add_term env facts t1 ex in
	add_term env facts t2 ex
      | A.Distinct (_, lt)
      | A.Builtin (_, _, lt) ->
	let env =
          List.fold_left
	    (fun env t-> add_term env facts t ex)
            env  lt
        in
	let lvs = concat_leaves env.uf lt in (* A verifier *)
	List.fold_left (* add Distinct and Builtin to Use *)
	  (fun env rx ->
	    let st, sa = Use.find rx env.use in
	    { env with
	      use = Use.add rx (st,SetA.add (a, ex) sa) env.use }
	  ) env lvs

  let semantic_view env (a, ex, orig) facts =
    match a with
    | LTerm a -> (* Over terms: add terms + term_canonical_view *)
      let env = add env facts a ex in
      let sa, ex = term_canonical_view env a ex in
      env, (sa, Some a, ex, orig)

    | LSem sa ->
      match sa with
      | A.Builtin _ -> (* we put it in canonical form for FM *)
        let sa, ex = canonical_view env sa ex in
        env, (sa, None, ex, orig)

      | _ ->
        (* XXX if we do canonical_view for
           A.Distinct, the theory of arrays will get lost *)
        env, (sa, None, ex, orig)

  let assume_eq env facts r1 r2 ex =
    Options.tool_req 3 "TR-CCX-Congruence";
    let env = congruence_closure env facts r1 r2 ex in
    if Options.nocontracongru () || X.type_info r1 != Ty.Tbool then env
    else begin
      contra_congruence env facts r1;
      contra_congruence env facts r2;
      env
    end

  let assume_dist env facts lr ex =
    Options.tool_req 3 "TR-CCX-Distinct";
    if Uf.already_distinct env.uf lr then env
    else  {env with uf = Uf.distinct env.uf lr ex}

  let rec assume_equalities env choices facts =
    if Q.is_empty facts.equas then env, choices
    else begin
      Debug.facts facts "equalities";
      let e = Q.pop facts.equas in
      Q.push e facts.ineqs; (*XXX also added in touched by congruence_closure*)
      let env, (sa, root, ex, orig) =  semantic_view env e facts in
      Debug.assume_literal sa;
      let env = match sa with
        | A.Pred (r1,neg) ->
          let r2, r3 =  if neg then X.bot(), X.top() else X.top(), X.bot() in
          if X.hash_cmp r1 r2 = 0 then env
          else
            let env = assume_eq env facts r1 r2 ex in
            assume_dist env facts [r1;r3] ex
        | A.Eq(r1, r2) ->
          if X.hash_cmp r1 r2 = 0 then env
          else assume_eq env facts r1 r2 ex
        | _ -> assert false
      in
      assume_equalities env choices facts
    end

  let rec assume_disequalities env choices facts =
    if Q.is_empty facts.diseqs then env, choices
    else begin
      Debug.facts facts "disequalities";
      let e = Q.pop facts.diseqs in
      Q.push e facts.ineqs;
      let env, (sa, root, ex, orig) = semantic_view env e facts in
      Debug.assume_literal sa;
      let env = match sa with
        | A.Distinct (false, lr) -> assume_dist env facts lr ex
	| A.Distinct (true, _) -> assert false
        | A.Pred _ ->
          Q.push (LSem sa, ex, orig) facts.equas;
          env
        | _ -> assert false
      in
      if Q.is_empty facts.equas then assume_disequalities env choices facts
      else env, choices (* Return to give priority to equalities *)
    end

  let rec norm_queue env ineqs (facts:r Sig.facts) =
    if Q.is_empty facts.ineqs then env, List.rev ineqs
    else
      let e = Q.pop facts.ineqs in
      let env, e' = semantic_view env e facts in
      let ineqs = e'::ineqs in
      let ineqs =
        match e with
        (* for case-split, to be sure that CS is given
           back to relations *)
        | LSem ra, ex, ((Sig.CS _ | Sig.NCS _) as orig) ->
          (ra, None, ex, orig) :: ineqs
        | _ -> ineqs
      in
      norm_queue env ineqs facts

  let add_touched uf acc (facts:r Sig.facts) =
    let acc =
      Util.MI.fold
        (fun _ x acc ->
          let y, ex = Uf.find_r uf x in (*use terms ? *)
          (LR.mkv_eq x y, None, ex, Sig.Subst) :: acc)
        facts.touched acc
    in
    facts.touched <- Util.MI.empty;
    acc

  let rec assume_inequalities env choices facts =
    Options.tool_req 3 "TR-CCX-Builtin";
    if Q.is_empty facts.ineqs then env, choices
    else begin
      Debug.facts facts "inequalities";
      let env, ineqs = norm_queue env [] facts in
      let ineqs = add_touched env.uf ineqs facts in
      let env, l = replay_atom env ineqs in
      List.iter (add_fact facts) l;
      env, List.rev_append l choices
    end

  let rec assume_literals env choices facts =
    match Q.is_empty facts.equas with
    | false ->
      let env, choices = assume_equalities env choices facts in
      assume_literals env choices facts
    | true ->
      match Q.is_empty facts.diseqs with
      | false ->
        let env, choices = assume_disequalities env choices facts in
        assume_literals env choices facts
      | true ->
        match Q.is_empty facts.ineqs with
        | false ->
          let env, choices = assume_inequalities env choices facts in
          assume_literals env choices facts
        | true -> env, choices


  let theories_instances ~do_syntactic_matching t_match env selector =
    let rel, th_instances =
      Rel.instantiate
        ~do_syntactic_matching t_match env.relation env.uf selector in
    {env with relation=rel}, th_instances

  let add_term env facts t ex =
    let env = add_term env facts t ex in
    env, facts

  let add env facts a ex =
    let env = add env facts a ex in
    env, facts

  (* End: new implementation of add, add_term, assume_literals and all that *)

  let case_split env ~for_model =
    match Rel.case_split env.relation env.uf for_model with
    | [] when for_model ->
      let l, uf = Uf.assign_next env.uf in
      (* try to not to modify uf in the future. It's currently done only
         to add fresh terms in UF to avoid loops *)
      l, {env with uf}
    | l -> l, env

  let query env a =
    let ra, ex_ra = term_canonical_view env a Ex.empty in
    Rel.query env.relation env.uf (ra, Some a, ex_ra, Sig.Other)

  let new_terms env = Rel.new_terms env.relation

  let class_of env t = Uf.class_of env.uf t

  let are_equal env t1 t2 = Uf.are_equal env.uf t1 t2

  let are_distinct env t1 t2 = Uf.are_distinct env.uf t1 t2

  let cl_extract env = Uf.cl_extract env.uf

  let term_repr env t = Uf.term_repr env.uf t

  let get_union_find env = env.uf

  let print_model fmt env =
    let zero = ref true in
    let eqs, neqs = Uf.model env.uf in
    let rs =
      List.fold_left (fun acc (r, l, to_rel) ->
	if l != [] then begin
	  if !zero then begin
	    fprintf fmt "Theory:";
	    zero := false;
	  end;
	  fprintf fmt "\n %a = %a" (T.print_list_sep " = ") l X.print r;
	end;
	to_rel@acc
      ) [] eqs in
    List.iter (fun lt ->
      if !zero then begin
	fprintf fmt "Theory:";
	zero := false;
      end;
      fprintf fmt "\n %a" (T.print_list_sep " <> ") lt;
    ) neqs;
    if not !zero then fprintf fmt "\n@.";
    Rel.print_model fmt env.relation rs

  let assume_th_elt env th_elt =
    {env with relation = Rel.assume_th_elt env.relation th_elt}

  let retrieve_used_context env dep =
    Rel.retrieve_used_context env.relation dep

end
