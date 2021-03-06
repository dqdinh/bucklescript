(* Copyright (C) 2015-2016 Bloomberg Finance L.P.
 * 
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 * 
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)








let simplify_alias 
    (meta : Lam_stats.meta)
    (lam : Lam.t) 
  :  Lam.t  = 

  let rec simpl  (lam : Lam.t) : Lam.t = 
    match lam with 
    | Lvar v -> 
      (* GLOBAL module needs to be propogated *)
      (try Lam.var (Hashtbl.find meta.alias_tbl v) with Not_found -> lam )
    | Llet(kind, k, (Lprim {primitive = Pgetglobal i; args = [] ; _} as g),
           l ) -> 
      (* This is detection of MODULE ALIAS 
          we need track all global module aliases, when it's
          passed as a parameter(escaped), we need do the expansion
          since global module access is not the same as local module
          TODO: 
          since we aliased k, so it's safe to remove it?
      *)
      let v = simpl l in
      if Ident_set.mem k meta.export_idents 
      then 
        Lam.let_ kind k g v
        (* in this case it is preserved, but will still be simplified 
            for the inner expression
        *)
      else v
    | Lprim {primitive = Pfield (i,_); args =  [Lvar v]; _} -> 
      (* ATTENTION: 
         Main use case, we should detect inline all immutable block .. *)
      Lam_util.get lam v  i meta.ident_tbl 
    | Lifthenelse(Lvar id as l1, l2, l3) 
      -> 
      begin match Hashtbl.find meta.ident_tbl id with 
      | ImmutableBlock ( _, Normal)
      | MutableBlock _  
        -> simpl l2 
      | ImmutableBlock ( [| SimpleForm l |]  , x) 
        -> 
        let l1 = 
          match x with 
          | Null 
            -> Lam.not_ (Location.none) ( Lam.prim ~primitive:Lam.Prim.js_is_nil ~args:[l] Location.none) 
          | Undefined 
            -> 
            Lam.not_  Location.none (Lam.prim ~primitive:Lam.Prim.js_is_undef ~args:[l] Location.none)
          | Null_undefined
            -> 
            Lam.not_ Location.none
              ( Lam.prim ~primitive:Lam.Prim.js_is_nil_undef  ~args:[l] Location.none) 
          | Normal ->  l1 
        in 
        Lam.if_ l1 (simpl l2) (simpl l3)
      | _ -> Lam.if_ l1 (simpl l2) (simpl l3)

      | exception Not_found -> Lam.if_ l1 (simpl l2) (simpl l3)
      end
    | Lifthenelse (l1, l2, l3) -> 
        Lam.if_ (simpl  l1) (simpl  l2) (simpl  l3)

    | Lconst _ -> lam
    | Llet(str, v, l1, l2) ->
      Lam.let_ str v (simpl l1) (simpl l2 )
    | Lletrec(bindings, body) ->
      let bindings = List.map (fun (k,l) ->  (k, simpl l) ) bindings in 
      Lam.letrec bindings (simpl body) 
    | Lprim {primitive; args; loc } 
      -> Lam.prim ~primitive ~args:(List.map simpl  args) loc

    (* complicated 
        1. inline this function
        2. ...
        exports.Make=
        function(funarg)
      {var $$let=Make(funarg);
        return [0, $$let[5],... $$let[16]]}
    *)      
    | Lapply{fn = 
               Lprim {primitive = Pfield (index, _) ;
                      args = [Lprim {primitive = Pgetglobal ident; args =  []}];
                      _} as l1;
             args; loc ; status} ->
      begin
        Lam_compile_env.find_and_add_if_not_exist (ident,index) meta.env
          ~not_found:(fun _ -> assert false)
          ~found:(fun i ->
              match i with
              | {closed_lambda=Some Lfunction{params; body; _} } 
                (** be more cautious when do cross module inlining *)
                when
                  ( Ext_list.same_length params args &&
                    List.for_all (fun (arg : Lam.t) ->
                        match arg with 
                        | Lvar p -> 
                          begin 
                            try Hashtbl.find meta.ident_tbl p <> Parameter
                            with Not_found -> true
                          end
                        |  _ -> true 
                      ) args) -> 
                simpl @@
                Lam_beta_reduce.propogate_beta_reduce
                  meta params body args
              | _ -> 
                Lam.apply (simpl l1) (List.map simpl args) loc status
            )

      end
    (* Function inlining interact with other optimizations...

        - parameter attributes
        - scope issues 
        - code bloat 
    *)      
    | Lapply{fn = (Lvar v as fn);  args; loc ; status} ->
      (* Check info for always inlining *)

      (* Ext_log.dwarn __LOC__ "%s/%d" v.name v.stamp;     *)
      let normal () = Lam.apply ( simpl fn) (List.map simpl args) loc status in
      begin 
        match Hashtbl.find meta.ident_tbl v with
        | Function {lambda = Lfunction {params; body} as _m;
                    rec_flag;                     
                    _ }
          -> 
        
          if Ext_list.same_length args params (* && false *)
          then               
            if Lam_inline_util.maybe_functor v.name  
              (* && (Ident_set.mem v meta.export_idents) && false *)
            then 
              (* TODO: check l1 if it is exported, 
                 if so, maybe not since in that case, 
                 we are going to have two copy?
              *)

              (* Check: recursive applying may result in non-termination *)
              begin
                (* Ext_log.dwarn __LOC__ "beta .. %s/%d" v.name v.stamp ; *)
                simpl (Lam_beta_reduce.propogate_beta_reduce meta params body args) 
              end
            else 
            if (* Lam_analysis.size body < Lam_analysis.small_inline_size *)
              Lam_analysis.ok_to_inline ~body params args 
            then 

                (* let param_map =  *)
                (*   Lam_analysis.free_variables meta.export_idents  *)
                (*     (Lam_analysis.param_map_of_list params) body in *)
                (* let old_count = List.length params in *)
                (* let new_count = Ident_map.cardinal param_map in *)
                let param_map = 
                  Lam_analysis.is_closed_with_map 
                    meta.export_idents params body in
                let is_export_id = Ident_set.mem v meta.export_idents in
                match is_export_id, param_map with 
                | false, (_, param_map)
                | true, (true, param_map) -> 
                  if rec_flag = Rec then               
                    begin
                      (* Ext_log.dwarn __LOC__ "beta rec.. %s/%d" v.name v.stamp ; *)
                      (* Lam_beta_reduce.propogate_beta_reduce meta params body args *)
                      Lam_beta_reduce.propogate_beta_reduce_with_map meta param_map params body args
                    end
                  else 
                    begin
                      (* Ext_log.dwarn __LOC__ "beta  nonrec..[%d] [%a]  %s/%d"  *)
                      (*   (List.length args)  *)
                      (*   Printlambda.lambda body                      *)
                      (*   v.name v.stamp ; *)
                      simpl (Lam_beta_reduce.propogate_beta_reduce_with_map meta param_map params body args)

                    end
                | _ -> normal ()
              else 
                normal ()
          else
            normal ()
        | _ -> normal ()
        | exception Not_found -> normal ()

      end

    | Lapply{ fn = Lfunction{ kind = Curried ; params; body}; args; _}
      when  Ext_list.same_length params args ->
      simpl (Lam_beta_reduce.propogate_beta_reduce meta params body args)
    | Lapply{ fn = Lfunction{kind =  Tupled;  params; body}; 
             args = [Lprim {primitive = Pmakeblock _; args; _}]; _}
      (** TODO: keep track of this parameter in ocaml trunk,
          can we switch to the tupled backend?
      *)
      when  Ext_list.same_length params args ->
      simpl (Lam_beta_reduce.propogate_beta_reduce meta params body args)

    | Lapply {fn = l1; args =  ll;  loc ; status} ->
      Lam.apply (simpl  l1) (List.map simpl  ll) loc status
    | Lfunction {arity; kind; params; body = l}
      -> Lam.function_ ~arity ~kind ~params  ~body:(simpl  l)
    | Lswitch (l, {sw_failaction; 
                   sw_consts; 
                   sw_blocks;
                   sw_numblocks;
                   sw_numconsts;
                  }) ->
      Lam.switch (simpl  l)
               {sw_consts = 
                  List.map (fun (v, l) -> v, simpl  l) sw_consts;
                sw_blocks = List.map (fun (v, l) -> v, simpl  l) sw_blocks;
                sw_numconsts = sw_numconsts;
                sw_numblocks = sw_numblocks;
                sw_failaction = 
                  begin 
                    match sw_failaction with 
                    | None -> None
                    | Some x -> Some (simpl x)
                  end}
    | Lstringswitch(l, sw, d) ->
      Lam.stringswitch (simpl  l )
                    (List.map (fun (i, l) -> i,simpl  l) sw)
                    (match d with
                     | Some d -> Some (simpl d )
                     | None -> None)
    | Lstaticraise (i,ls) -> 
      Lam.staticraise i (List.map simpl  ls)
    | Lstaticcatch (l1, ids, l2) -> 
      Lam.staticcatch (simpl  l1) ids (simpl  l2)
    | Ltrywith (l1, v, l2) -> Lam.try_ (simpl  l1) v (simpl  l2)

    | Lsequence (Lprim {primitive = Pgetglobal (id); args = []}, l2)
      when Lam_compile_env.is_pure (Lam_module_ident.of_ml id) 
      -> simpl l2
    | Lsequence(l1, l2)
      -> Lam.seq (simpl  l1) (simpl  l2)
    | Lwhile(l1, l2)
      -> Lam.while_ (simpl  l1) (simpl l2)
    | Lfor(flag, l1, l2, dir, l3)
      -> 
      Lam.for_ flag (simpl  l1) (simpl  l2) dir (simpl  l3)
    | Lassign(v, l) ->
      (* Lalias-bound variables are never assigned, so don't increase
         v's refsimpl *)
      Lam.assign v (simpl  l)
    | Lsend (u, m, o, ll, v) 
      -> 
      Lam.send u (simpl m) (simpl o) (List.map simpl ll) v
    | Lifused (v, l) -> Lam.ifused v (simpl  l)
  in 
  simpl lam
