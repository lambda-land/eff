open Typed


let unary_inlinable f ty1 ty2 = 
  let x = Typed.Variable.fresh "x"
  and f = Typed.Variable.fresh f
  and loc = Location.unknown in
  let drt = Type.fresh_dirt () in
  let p = {
    term = (Pattern.Var x, loc);
    location = loc;
    scheme = Scheme.simple ty1
  } in
  pure_lambda ~loc @@
    pure_abstraction ~loc p @@
      pure_apply ~loc
        (var ~loc f (Scheme.simple (Type.Arrow (ty1, (ty2, drt)))))
        (var ~loc x (Scheme.simple ty1))

let binary_inlinable f ty1 ty2 ty =
  let x1 = Typed.Variable.fresh "x1"
  and x2 = Typed.Variable.fresh "x2"
  and f = Typed.Variable.fresh f
  and loc = Location.unknown
  and drt = Type.fresh_dirt () in
  let p1 = {
    term = (Pattern.Var x1, loc);
    location = loc;
    scheme = Scheme.simple ty1
  }
  and p2 = {
    term = (Pattern.Var x2, loc);
    location = loc;
    scheme = Scheme.simple ty2
  } in
  lambda ~loc @@
    abstraction ~loc p1 @@
      value ~loc @@
        lambda ~loc @@
          abstraction ~loc p2 @@
            value ~loc @@
              pure_apply ~loc (
                pure_apply ~loc
                  (var ~loc f (Scheme.simple (Type.Arrow (ty1, (Type.Arrow (ty2, (ty, drt)), drt)))))
                  (var ~loc x1 (Scheme.simple ty1))
              ) (var ~loc x2 (Scheme.simple ty2))

let inlinable_definitions =
  [("+", binary_inlinable "Pervasives.(+)" Type.int_ty Type.int_ty Type.int_ty)]

let inlinable = ref []


let rec optimize_comp c = shallow_opt ( opt_sub_comp c)

and shallow_opt c = 
  (* Print.debug "Shallow optimizing %t" (CamlPrint.print_computation c); *)
  match c.term with

 (*| Let (pclist,c2) -> let [(p1,c1)] = pclist in
                        optimize_comp (bind ~loc:c.location c1 (abstraction ~loc:c.location p1 c2)) *)

  | Let (pclist,c2) ->  optimize_comp (folder pclist c2)
  
  | Bind (c1, c2) ->
    begin match c1.term with
    (*Bind x (Value e) c -> LetC x e c*)
    | Value e ->  shallow_opt(let_in ~loc:c.location e c2)
    | Bind (c3,c4) -> let (p1,cp1) = c2.term in 
                      let (p2,cp2) = c4.term in 
                      shallow_opt (bind ~loc:c.location c1 (abstraction ~loc:c.location p2 
                                              (bind ~loc:c.location cp2 (abstraction ~loc:c.location p1 cp1))))
    | LetIn(e,a) ->let (pa,ca) = a.term in
                   let newbind = shallow_opt (bind ~loc:c.location ca c2) in 
                   let let_abs = abstraction ~loc:c.location pa newbind in
                   shallow_opt (let_in ~loc:c.location e let_abs)

    | Apply(e1,e2) -> let (p,ca) = c2.term in
                      begin match e1.term with
                     | Effect ef -> begin match ca.term with 
                                   | Apply(e3,e4) -> 
                                          begin match e4.term with 
                                          | Var x -> begin match e3.term with
                                                     | Lambda k -> begin match (fst p.term)  with
                                                                   | Pattern.Var pv when (pv = x) ->
                                                                       shallow_opt (call ~loc:c.location ef e2 k)
                                                                   | _-> c
                                                                 end
                                                     | _-> c
                                                     end
                                          |  _ ->  c  
                                          end
                                   | _ -> c
                                   end
                     | _ -> c
                     end                                   
    

    | Call(eff,e,k) ->  let (pa,ca) = c2.term in
                        let loc = Location.unknown in
                        let z = Typed.Variable.fresh "z" in 
                        let( _ , (input_k_ty , _) , _ ) = k.scheme in
                        let pz = {
                                  term = (Pattern.Var z, loc);
                                  location = loc;
                                  scheme = Scheme.simple input_k_ty
                                } in
                        let vz = var ~loc:loc z (Scheme.simple input_k_ty) in
                        let (p_k,c_k) = k.term in 
                        let k_lambda = lambda ~loc:loc (abstraction ~loc:loc p_k c_k) in
                        let inner_apply = shallow_opt (apply ~loc:loc k_lambda vz) in
                        let inner_bind = shallow_opt (bind ~loc:loc inner_apply (abstraction ~loc:loc pa ca)) in
                        shallow_opt (call ~loc:loc eff e (abstraction ~loc:loc pz inner_bind))
    | _ -> c
    end

  | Handle (e1,c1) ->
    begin match c1.term with

    (*Handle h (LetC x e c) -> LetC (x e) (Handle c h)*)
    | LetIn (e2,a) -> let (p,c2) = a.term in 
                     shallow_opt(
                      let_in ~loc:c.location e2 (abstraction ~loc:c.location p (shallow_opt (handle ~loc:c.location e1 c2)))
                    )
    
    | Value v -> begin match e1.term with
    
                 (*Handle (Handler vc ocs) (Value v) -> Apply (Lambda vc) v *)
                 | Handler h -> shallow_opt(
                                apply ~loc:c.location (lambda ~loc:c.location h.value_clause) v)
                 | _-> c
                 end

    | Call (eff,exp,k) -> begin match e1.term with
                          | Handler h -> 
                                let loc = Location.unknown in
                                let z = Typed.Variable.fresh "z" in 
                                let( _ , (input_k_ty , _) , _ ) = k.scheme in
                                let pz = {
                                          term = (Pattern.Var z, loc);
                                          location = loc;
                                          scheme = Scheme.simple input_k_ty
                                        } in
                                let vz = var ~loc:loc z (Scheme.simple input_k_ty) in
                                let (p_k,c_k) = k.term in 
                                let k_lambda = lambda ~loc:loc (abstraction ~loc:loc p_k c_k) in
                                let e2_apply = shallow_opt (apply ~loc:loc k_lambda vz) in
                                let e2_handle = shallow_opt (handle ~loc:loc e1 e2_apply) in
                                let e2_lambda = lambda ~loc:loc (abstraction ~loc:loc pz e2_handle) in
                                begin match Common.lookup eff h.effect_clauses with
                                        | Some result -> 
                                          let (p1,p2,cresult) = result.term in
                                          let e1_lamda =  lambda ~loc:loc (abstraction ~loc:loc p2 cresult) in
                                          let e1_purelambda = pure_lambda ~loc:loc (pure_abstraction ~loc:loc p1 e1_lamda) in
                                          let e1_pureapply = pure_apply ~loc:loc e1_purelambda exp in
                                          shallow_opt (apply ~loc:loc e1_pureapply e2_lambda)

                                        | None ->
                                          let call_abst = abstraction ~loc:loc pz e2_handle in
                                          shallow_opt (call ~loc:loc eff exp call_abst )
                                        end
                          | _-> c
                          end
    | _ -> c
    end
  | Apply (e1,e2) ->
     begin match e1.term with
     (*Apply (PureLambda a) e -> Value (PureApply (PureLambda a) e)*)
     | Lambda a ->
          let (p,c') = a.term in
          if is_atomic e2 
            then  
                let Pattern.Var vp = (fst p.term) in
                let tempvar = var ~loc:c.location  vp p.scheme in
                let Var v = tempvar.term in
                optimize_comp (substitute_var_comp c' v e2)
          else 
          begin match c'.term with 
          | Value v -> shallow_opt (value ~loc:c.location @@ 
              pure_apply ~loc:c.location (pure_lambda ~loc:e1.location (pure_abstraction ~loc:a.location p v)) e2)
          | _ -> c
          end
     | PureLambda pure_abs ->    shallow_opt (value ~loc:c.location 
                                 (pure_apply ~loc:c.location (pure_lambda ~loc:c.location pure_abs) e2 ))
     | _ -> c
     end
  
  | LetIn (e,a) ->
      let (p,cp) = a.term in
      begin match cp.term with
      | Value e2 -> shallow_opt (value ~loc:c.location (pure_let_in ~loc:c.location e (pure_abstraction ~loc:c.location p e2)))
      | _ -> c
      end

  | _ -> c

and optimize_abstraction abs = let (p,c) = abs.term in abstraction ~loc:abs.location p (optimize_comp c) 


and optimize_pure_abstraction abs = let (p,e) = abs.term in pure_abstraction ~loc:abs.location p (optimize_expr e)

and folder pclist cn = 
    let func = fun a ->  fun b ->  (bind ~loc:b.location (snd a) (abstraction ~loc:b.location (fst a) b ) )
    in  List.fold_right func pclist cn

and  optimize_expr e =

  match e.term with
  | Lambda a -> 
    let (p,c) = a.term in
    begin match c.term with 
    (*Lambda (x, Value e) -> PureLambda (x, e)
     | Value v -> optimize_expr (pure_lambda ~loc:e.location (pure_abstraction ~loc:e.location p v)) *)
    | _ -> e
    end
  | _ -> e

and opt_sub_comp c =
  (* Print.debug "Optimizing %t" (CamlPrint.print_computation c); *)
  match c.term with
  | Value e -> value ~loc:c.location (opt_sub_expr e)
  | LetRec (li, c1) -> let_rec' ~loc:c.location li (optimize_comp c1)
  | Match (e, li) -> match' ~loc:c.location (opt_sub_expr e) li
  | While (c1, c2) -> while' ~loc:c.location (optimize_comp c1) (optimize_comp c2)
  | For (v, e1, e2, c1, b) -> for' ~loc:c.location v (opt_sub_expr e1) (opt_sub_expr e2) (optimize_comp c1) b
  | Apply (e1, e2) -> apply ~loc:c.location (opt_sub_expr e1) (opt_sub_expr e2)
  | Handle (e, c1) -> handle ~loc:c.location (opt_sub_expr e) (optimize_comp c1)
  | Check c1 -> check ~loc:c.location (optimize_comp c1)
  | Call (eff, e1, a1) -> call ~loc:c.location eff (opt_sub_expr e1) (optimize_abstraction a1) 
  | Bind (c1, a1) -> bind ~loc:c.location (optimize_comp c1) (optimize_abstraction a1)
  | LetIn (e, a) -> let_in ~loc: c.location(opt_sub_expr e) (optimize_abstraction a)
  | _ -> c

and opt_sub_expr e =
  (* Print.debug "Optimizing %t" (CamlPrint.print_expression e); *)
  match e.term with
  | Const c -> const ~loc:e.location c
  | Tuple lst -> tuple ~loc:e.location lst
  | Lambda a -> lambda ~loc:e.location (optimize_abstraction a)
  | PureLambda pa -> pure_lambda ~loc:e.location (optimize_pure_abstraction pa)
  | PureApply (e1, e2)-> pure_apply ~loc:e.location (optimize_expr e1) (optimize_expr e2)
  | PureLetIn (e1, pa) -> pure_let_in ~loc:e.location (optimize_expr e1) (optimize_pure_abstraction pa)
  | Var x -> 
      begin match Common.lookup x !inlinable with
      | Some e -> opt_sub_expr e
      | _ -> e
      end
  | _ -> e


and is_atomic e = begin match e.term with 
                    | Var _ -> true
                    | Const _ -> true
                    | _ -> false
                  end


and substitute_var_comp comp var exp =
  (* Print.debug "Substituting %t" (CamlPrint.print_computation comp); *)
        let loc = Location.unknown in
        begin match comp.term with
          | Value e -> value ~loc:loc (substitute_var_exp e var exp)
          | Let (list,cf) ->  let' ~loc:loc list cf
          | LetRec (li, c1) -> let_rec' ~loc:loc li c1
          | Match (e, li) -> match' ~loc:loc e li
          | While (c1, c2) -> while' ~loc:loc (substitute_var_comp c1 var exp) (substitute_var_comp c2 var exp)
          | For (v, e1, e2, c1, b) -> for' ~loc:loc v (substitute_var_exp e1 var exp) (substitute_var_exp e2 var exp) (substitute_var_comp c1 var exp) b
          | Apply (e1, e2) -> apply ~loc:loc (substitute_var_exp e1 var exp) (substitute_var_exp e2 var exp)
          | Handle (e, c1) -> handle ~loc:loc (substitute_var_exp e var exp) (substitute_var_comp c1 var exp)
          | Check c1 -> check ~loc:loc (substitute_var_comp c1 var exp)
          | Call (eff, e1, a1) -> call ~loc:loc eff (substitute_var_exp e1 var exp )  a1
          | Bind (c1, a1) -> let (p1,cp1) = a1.term in 
                             begin match (fst p1.term)  with
                             | Pattern.Var pv when ( var !=  pv ) -> bind ~loc:loc (substitute_var_comp c1 var exp) (abstraction ~loc:loc p1 (substitute_var_comp cp1 var exp))
                             | _->bind ~loc:loc (substitute_var_comp c1 var exp) a1
                             end
          | LetIn (e, a) -> let (p1,cp1) = a.term in 
                             begin match (fst p1.term) with
                             | Pattern.Var pv when (pv != var) -> let_in ~loc:loc (substitute_var_exp e var exp) (abstraction ~loc:loc p1 (substitute_var_comp cp1 var exp))
                             | _->let_in ~loc:loc e a
                             end
          | _ -> comp
        end
and substitute_var_exp e var exp = 
  (* Print.debug "Substituting %t" (CamlPrint.print_expression e); *)
    let loc = Location.unknown in
    begin match e.term with 
      | Var v when (v = var) -> print_endline "did a sub" ; exp
      (*| Tuple lst -> tuple ~loc:loc (substitute_var_exp_list lst var exp) *)
      | Lambda a -> let (p,c) = a.term in
                    begin match (fst p.term) with
                    | Pattern.Var pv when (pv != var) -> lambda ~loc:loc (abstraction ~loc:loc p (substitute_var_comp c var exp))
                    | _ -> lambda ~loc:loc (abstraction ~loc:loc p c )
                  end
   (*   | Handler of handler *)
      | PureLambda pa -> let (p,ea) = pa.term in
                      begin match (fst p.term) with
                    | Pattern.Var pv when (pv != var) -> pure_lambda ~loc:loc (pure_abstraction ~loc:loc p (substitute_var_exp ea var exp))
                    | _ -> pure_lambda ~loc:loc (pure_abstraction ~loc:loc p ea )
                  end
      | PureApply (e1,e2) -> pure_apply ~loc:loc (substitute_var_exp e1 var exp) (substitute_var_exp e2 var exp)
   (*   | PureLetIn (e,pa) -> pure_let_in ~loc:loc expression * pure_abstraction *)
      | _ -> e
    end

let optimize_command = function
  | Typed.Computation c ->
      Some (Typed.Computation (optimize_comp c))
  | Typed.TopLet (defs, vars) ->
      Some (Typed.TopLet (Common.assoc_map optimize_comp defs, vars))
  | Typed.TopLetRec (defs, vars) ->
      Some (Typed.TopLetRec (Common.assoc_map optimize_abstraction defs, vars))
  | (Typed.DefEffect _ | Typed.Reset | Typed.Quit | Typed.Use _ | Typed.Tydef _) as cmd ->
      Some cmd
  | Typed.External (x, _, f) as cmd ->
      begin match Common.lookup f inlinable_definitions with
      | None -> Some cmd
      | Some e ->
          inlinable := Common.update x e !inlinable; Some cmd
      end
  | (Typed.TypeOf _ | Typed.Help) -> None

let rec optimize_commands = function
  | [] -> []
  | (cmd, loc) :: cmds ->
      let cmd = optimize_command cmd in
      let cmds = optimize_commands cmds in
      begin match cmd with
      | Some cmd -> (cmd, loc) :: cmds
      | None -> cmds
      end




