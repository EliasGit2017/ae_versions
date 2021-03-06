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

open Options
open Format
open Sig

module Sy = Symbols
module T  = Term
module A  = Literal
module L  = List

type 'a abstract = unit

module type ALIEN = sig
  include Sig.X
  val embed : r abstract -> r
  val extract : r -> (r abstract) option
end

module Shostak (X : ALIEN) = struct

  type t = X.r abstract
  type r = X.r

  let name           = "Farrays"
  let is_mine_symb _ = false
  let fully_interpreted sb = assert false
  let type_info _    = assert false
  let color _        = assert false
  let print _ _      = assert false
  let embed _        = assert false
  let is_mine _      = assert false
  let compare _ _    = assert false
  let equal _ _      = assert false
  let hash _         = assert false
  let leaves _       = assert false
  let subst _ _ _    = assert false
  let make _         = assert false
  let term_extract _ = None, false
  let abstract_selectors p acc = assert false
  let solve r1 r2 = assert false
  let assign_value r _ eq =
    if List.exists (fun (t,_) -> (Term.view t).Term.depth = 1) eq then None
    else
      match X.term_extract r with
      | Some t, true ->
        Some (Term.fresh_name (X.type_info r), false)
      | _ -> assert false

  let choose_adequate_model t _ l =
    let acc =
      List.fold_left
        (fun acc (s, r) ->
          if (Term.view s).Term.depth <> 1 then acc
          else
            match acc with
            | Some(s', r') when Term.compare s' s > 0 -> acc
            | _ -> Some (s, r)
        ) None l
    in
    match acc with
    | Some (_, r) ->
      ignore (flush_str_formatter ());
      fprintf str_formatter "%a" X.print r; (* it's a EUF constant *)
      r, flush_str_formatter ()

    | _ -> assert false

end

module Relation (X : ALIEN) (Uf : Uf.S) = struct

  open Sig
  module Ex = Explanation

  type r = X.r
  type uf = Uf.t

  module LR =
    Literal.Make(struct type t = X.r  let compare = X.hash_cmp include X end)

  (* map get |-> { set } des associations (get,set) deja splites *)
  module Tmap = struct
    include T.Map
    let update t a mp =
      try add t (T.Set.add a (find t mp)) mp
      with Not_found -> add t (T.Set.singleton a) mp
    let splited t a mp = try T.Set.mem a (find t mp) with Not_found -> false
  end

  module LRset= LR.Set

  module Conseq =
    Set.Make
      (struct
        type t = A.LT.t * Ex.t
        let compare (lt1,_) (lt2,_) = A.LT.compare lt1 lt2
       end)
  (* map k |-> {sem Atom} d'egalites/disegalites sur des atomes semantiques*)
  module LRmap = struct
    include LR.Map
    let find k mp = try find k mp with Not_found -> Conseq.empty
    let add k v ex mp = add k (Conseq.add (v,ex) (find k mp)) mp
  end

  type gtype = {g:Term.t; gt:Term.t; gi:Term.t; gty:Ty.t}
  module G :Set.S with type elt = gtype = Set.Make
    (struct type t = gtype let compare t1 t2 = T.compare t1.g t2.g end)

  (* ensemble de termes "set" avec leurs arguments et leurs types *)
  type stype = {s:T.t; st:T.t; si:T.t; sv:T.t; sty:Ty.t}
  module S :Set.S with type elt = stype = Set.Make
    (struct type t = stype let compare t1 t2 = T.compare t1.s t2.s end)

  (* map t |-> {set(t,-,-)} qui associe a chaque tableau l'ensemble
     de ses affectations *)
  module TBS = struct
    include Map.Make(T)
    let find k mp = try find k mp with Not_found -> S.empty

    (* add reutilise find ci-dessus *)
    let add k v mp = add k (S.add v (find k mp)) mp
  end

  type t =
      {gets  : G.t;               (* l'ensemble des "get" croises*)
       tbset : S.t TBS.t ;        (* map t |-> set(t,-,-) *)
       split : LRset.t;           (* l'ensemble des case-split possibles *)
       conseq   : Conseq.t LRmap.t; (* consequences des splits *)
       seen  : T.Set.t Tmap.t;    (* combinaisons (get,set) deja splitees *)
       new_terms : T.Set.t;
       size_splits : Numbers.Q.t;
      }


  let empty _ =
    {gets  = G.empty;
     tbset = TBS.empty;
     split = LRset.empty;
     conseq   = LRmap.empty;
     seen  = Tmap.empty;
     new_terms = T.Set.empty;
     size_splits = Numbers.Q.one;
    }

  (*BISECT-IGNORE-BEGIN*)
  module Debug = struct

    let assume fmt la =
      if debug_arrays () && la != [] then begin
        fprintf fmt "[Arrays.Rel] We assume@.";
        L.iter (fun (a,_,_,_) -> fprintf fmt "  > %a@."
          LR.print (LR.make a)) la;
      end

    let print_gets fmt = G.iter (fun t -> fprintf fmt "%a@." T.print t.g)
    let print_sets fmt = S.iter (fun t -> fprintf fmt "%a@." T.print t.s)
    let print_splits fmt =
      LRset.iter (fun a -> fprintf fmt "%a@." LR.print a)
    let print_tbs fmt =
      TBS.iter (fun k v -> fprintf fmt "%a --> %a@." T.print k print_sets v)

    let env fmt env =
      if debug_arrays () then begin
        fprintf fmt "-- gets ----------------------------------------@.";
        print_gets fmt env.gets;
        fprintf fmt "-- tabs of sets --------------------------------@.";
        print_tbs fmt env.tbset;
        fprintf fmt "-- splits --------------------------------------@.";
        print_splits fmt env.split;
        fprintf fmt "------------------------------------------------@."
      end

    let new_equalities fmt st =
      if debug_arrays () then
        begin
          fprintf fmt "[Arrays] %d implied equalities@."
	    (Conseq.cardinal st);
          Conseq.iter (fun (a,ex) -> fprintf fmt "  %a : %a@."
            A.LT.print a Ex.print ex) st
        end

    let case_split a =
      if debug_arrays () then
        fprintf fmt "[Arrays.case-split] %a@." LR.print a

    let case_split_none () =
      if debug_arrays () then fprintf fmt "[Arrays.case-split] Nothing@."

  end
  (*BISECT-IGNORE-END*)

  (* met a jour gets et tbset en utilisant l'ensemble des termes donne*)
  let rec update_gets_sets acc t =
    let {T.f=f;xs=xs;ty=ty} = T.view t in
    let gets, tbset = List.fold_left update_gets_sets acc xs in
    match Sy.is_get f, Sy.is_set f, xs with
      | true , false, [a;i]   -> G.add {g=t; gt=a; gi=i; gty=ty} gets, tbset
      | false, true , [a;i;v] ->
        gets, TBS.add a {s=t; st=a; si=i; sv=v; sty=ty} tbset
      | false, false, _ -> (gets,tbset)
      | _  -> assert false

  (* met a jour les composantes gets et tbset de env avec les termes
     contenus dans les atomes de la *)
  let new_terms env la =
    let fct acc r =
      List.fold_left
        (fun acc x ->
          match X.term_extract x with
            | Some t, _ -> update_gets_sets acc t
            | None, _   -> acc
        )acc (X.leaves r)
    in
    let gets, tbset =
      L.fold_left
        (fun acc (a,_,_,_)->
          match a with
            | A.Eq (r1,r2) -> fct (fct acc r1) r2
            | A.Builtin (_,_,l) | A.Distinct (_, l) -> L.fold_left fct acc l
            | A.Pred (r1,_) -> fct acc r1
        ) (env.gets,env.tbset) la
    in
    {env with gets=gets; tbset=tbset}


  (* mise a jour de env avec les instances
     1) p   => p_ded
     2) n => n_ded *)
  let update_env are_eq are_dist dep env acc gi si p p_ded n n_ded =
    match are_eq gi si, are_dist gi si with
      | Sig.Yes (idep, _) , Sig.No ->
        let conseq = LRmap.add n n_ded dep env.conseq in
        {env with conseq = conseq},
        Conseq.add (p_ded, Ex.union dep idep) acc

      | Sig.No, Sig.Yes (idep, _) ->
        let conseq = LRmap.add p p_ded dep env.conseq in
        {env with conseq = conseq},
        Conseq.add (n_ded, Ex.union dep idep) acc

      | Sig.No, Sig.No ->
        let sp = LRset.add p env.split in
        let conseq = LRmap.add p p_ded dep env.conseq in
        let conseq = LRmap.add n n_ded dep conseq in
        { env with split = sp; conseq = conseq }, acc

      | Sig.Yes _,  Sig.Yes _ -> assert false

  (*----------------------------------------------------------------------
    get(set(-,-,-),-) modulo egalite
    ---------------------------------------------------------------------*)
  let get_of_set are_eq are_dist gtype (env,acc) class_of =
    let {g=get; gt=gtab; gi=gi; gty=gty} = gtype in
    L.fold_left
      (fun (env,acc) set ->
        if Tmap.splited get set env.seen then (env,acc)
        else
          let env = {env with seen = Tmap.update get set env.seen} in
          let {T.f=f;xs=xs;ty=sty} = T.view set in
          match Sy.is_set f, xs with
            | true , [stab;si;sv] ->
              let xi, _ = X.make gi in
              let xj, _ = X.make si in
              let get_stab  = T.make (Sy.Op Sy.Get) [stab;gi] gty in
              let p       = LR.mk_eq xi xj in
              let p_ded   = A.LT.mk_eq get sv in
              let n     = LR.mk_distinct false [xi;xj] in
              let n_ded = A.LT.mk_eq get get_stab in
              let dep = match are_eq gtab set with
                  Yes (dep, _) -> dep | No -> assert false
              in
              let env =
                {env with new_terms =
                    T.Set.add get_stab env.new_terms } in
              update_env
                are_eq are_dist dep env acc gi si p p_ded n n_ded
            | _ -> (env,acc)
      ) (env,acc) (class_of gtab)

  (*----------------------------------------------------------------------
    set(-,-,-) modulo egalite
    ---------------------------------------------------------------------*)
  let get_from_set are_eq are_dist stype (env,acc) class_of =
    let {s=set; st=stab; si=si; sv=sv; sty=sty} = stype in
    let ty_si = (T.view sv).T.ty in

    let stabs =
      L.fold_left
        (fun acc t -> S.union acc (TBS.find t env.tbset))
        S.empty (class_of stab)
    in

    S.fold (fun stab' (env,acc) ->
      let get = T.make (Sy.Op Sy.Get) [set; si] ty_si in
      if Tmap.splited get set env.seen then (env,acc)
      else
        let env = {env with
          seen = Tmap.update get set env.seen;
          new_terms = T.Set.add get env.new_terms }
        in
        let p_ded = A.LT.mk_eq get sv in
        env, Conseq.add (p_ded, Ex.empty) acc
    ) stabs (env,acc)

  (*----------------------------------------------------------------------
    get(t,-) and set(t,-,-) modulo egalite
    ---------------------------------------------------------------------*)
  let get_and_set are_eq are_dist gtype (env,acc) class_of =
    let {g=get; gt=gtab; gi=gi; gty=gty} = gtype in

    let suff_sets =
      L.fold_left
        (fun acc t -> S.union acc (TBS.find t env.tbset))
        S.empty (class_of gtab)
    in
    S.fold
      (fun  {s=set; st=stab; si=si; sv=sv; sty=sty} (env,acc) ->
        if Tmap.splited get set env.seen then (env,acc)
        else
          begin
            let env = {env with seen = Tmap.update get set env.seen} in
            let xi, _ = X.make gi in
            let xj, _ = X.make si in
            let get_stab  = T.make (Sy.Op Sy.Get) [stab;gi] gty in
            let gt_of_st  = T.make (Sy.Op Sy.Get) [set;gi] gty in
            let p       = LR.mk_eq xi xj in
            let p_ded   = A.LT.mk_eq gt_of_st sv in
            let n     = LR.mk_distinct false [xi;xj] in
            let n_ded = A.LT.mk_eq gt_of_st get_stab in
            let dep = match are_eq gtab stab with
                Yes (dep, _) -> dep | No -> assert false
            in
            let env =
              {env with new_terms =
                  T.Set.add get_stab (T.Set.add gt_of_st env.new_terms) } in
            update_env are_eq are_dist dep env acc gi si p p_ded n n_ded
          end
      ) suff_sets (env,acc)

  (* Generer de nouvelles instantiations de lemmes *)
  let new_splits are_eq are_dist env acc class_of =
    let accu =
      G.fold
        (fun gt_info accu ->
          let accu = get_of_set are_eq are_dist  gt_info accu class_of in
          get_and_set are_eq are_dist  gt_info accu class_of
        ) env.gets (env,acc)
    in
    TBS.fold (fun _ tbs accu ->
      S.fold
        (fun stype accu ->
          get_from_set are_eq are_dist stype accu class_of)
        tbs accu
    ) env.tbset accu



  (* nouvelles disegalites par instantiation du premier
     axiome d'exentionnalite *)
  let extensionality accu la class_of =
    List.fold_left
      (fun ((env, acc) as accu) (a, _, dep,_) ->
        match a with
          | A.Distinct(false, [r;s]) ->
            begin
              match X.type_info r, X.term_extract r, X.term_extract s with
                | Ty.Tfarray (ty_k, ty_v), (Some t1, _), (Some t2, _)  ->
                  let i  = T.fresh_name ty_k in
                  let g1 = T.make (Sy.Op Sy.Get) [t1;i] ty_v in
                  let g2 = T.make (Sy.Op Sy.Get) [t2;i] ty_v in
                  let d  = A.LT.mk_distinct false [g1;g2] in
                  let acc = Conseq.add (d, dep) acc in
                  let env =
                    {env with new_terms =
                        T.Set.add g2 (T.Set.add g1 env.new_terms) } in
                  env, acc
                | _ -> accu
            end
          | _ -> accu
      ) accu la

  let implied_consequences env eqs la =
    let spl, eqs =
      L.fold_left
        (fun (spl,eqs) (a,_,dep,_) ->
          let a = LR.make a in
          let spl = LRset.remove (LR.neg a) (LRset.remove a spl) in
          let eqs =
            Conseq.fold
              (fun (fact,ex) acc -> Conseq.add (fact, Ex.union ex dep) acc)
              (LRmap.find a env.conseq) eqs
          in
          spl, eqs
        )(env.split, eqs) la
    in
    {env with split=spl}, eqs

  (* deduction de nouvelles dis/egalites *)
  let new_equalities env eqs la class_of =
    let la = L.filter
      (fun (a,_,_,_) -> match a with A.Builtin _  -> false | _ -> true) la
    in
    let env, eqs = extensionality (env, eqs) la class_of in
    implied_consequences env eqs la

  (* choisir une egalite sur laquelle on fait un case-split *)
  let two = Numbers.Q.from_int 2

  let case_split env uf ~for_model =
    (*if Numbers.Q.compare
      (Numbers.Q.mult two env.size_splits) (max_split ()) <= 0  ||
      Numbers.Q.sign  (max_split ()) < 0 then*)
    try
      let a = LR.neg (LRset.choose env.split) in
      Debug.case_split a;
      [LR.view a, true, CS (Th_arrays, two)]
    with Not_found ->
      Debug.case_split_none ();
      []

  let count_splits env la =
    let nb =
      List.fold_left
        (fun nb (_,_,_,i) ->
          match i with
          | CS (Th_arrays, n) -> Numbers.Q.mult nb n
          | _ -> nb
        )env.size_splits la
    in
    {env with size_splits = nb}

  let assume env uf la =
    let are_eq = Uf.are_equal uf ~added_terms:true in
    let are_neq = Uf.are_distinct uf in
    let class_of = Uf.class_of uf in
    let env = count_splits env la in

    (* instantiation des axiomes des tableaux *)
    Debug.assume fmt la;
    let env = new_terms env la in
    let env, atoms = new_splits are_eq are_neq env Conseq.empty class_of in
    let env, atoms = new_equalities env atoms la class_of in
    (*Debug.env fmt env;*)
    Debug.new_equalities fmt atoms;
    let l =
      Conseq.fold (fun (a,ex) l -> ((LTerm a, ex, Sig.Other)::l)) atoms [] in
    env, { assume = l; remove = [] }


  let assume env uf la =
    if Options.timers() then
      try
	Timers.exec_timer_start Timers.M_Arrays Timers.F_assume;
	let res =assume env uf la in
	Timers.exec_timer_pause Timers.M_Arrays Timers.F_assume;
	res
      with e ->
	Timers.exec_timer_pause Timers.M_Arrays Timers.F_assume;
	raise e
    else assume env uf la

  let query _ _ _ = Sig.No
  let add env _ r _ = env
  let print_model _ _ _ = ()

  let new_terms env = env.new_terms
  let instantiate ~do_syntactic_matching _ env uf _ = env, []
  let retrieve_used_context _ _ = [], []

  let assume_th_elt t th_elt =
    match th_elt.Commands.extends with
    | Typed.Arrays ->
      failwith "This Theory does not support theories extension"
    | _ -> t


end
