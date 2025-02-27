(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Core_kernel
open Common
open Aast
open Tast
open Typing_defs
open Typing_env_types
open Utils
module TUtils = Typing_utils
module Reason = Typing_reason
module Env = Typing_env
module Union = Typing_union
module Inter = Typing_intersection
module SN = Naming_special_names
module TVis = Typing_visibility
module Phase = Typing_phase
module Subst = Decl_subst
module MakeType = Typing_make_type
module Cls = Decl_provider.Class
module Partial = Partial_provider

let err_witness env p = (Reason.Rwitness p, Typing_utils.terr env)

let smember_not_found pos ~is_const ~is_method class_ member_name =
  let kind =
    if is_const then
      `class_constant
    else if is_method then
      `static_method
    else
      `class_variable
  in
  let error hint =
    let cid = (Cls.pos class_, Cls.name class_) in
    Errors.smember_not_found kind pos cid member_name hint
  in
  let static_suggestion =
    Env.suggest_static_member is_method class_ member_name
  in
  let method_suggestion = Env.suggest_member is_method class_ member_name in
  match (static_suggestion, method_suggestion) with
  (* Prefer suggesting a different static method, unless there's a
     normal method whose name matches exactly. *)
  | (Some _, Some (def_pos, v)) when v = member_name ->
    error (`closest (def_pos, v))
  | (Some (def_pos, v), _) -> error (`did_you_mean (def_pos, v))
  | (None, Some (def_pos, v)) -> error (`closest (def_pos, v))
  | (None, None) when not (Cls.members_fully_known class_) ->
    (* no error in this case ... the member might be present
     * in one of the parents of class_ that the typing cannot see *)
    ()
  | (None, None) -> error `no_hint

let member_not_found pos ~is_method class_ member_name r =
  let kind =
    if is_method then
      `method_
    else
      `member
  in
  let cid = (Cls.pos class_, Cls.name class_) in
  let reason =
    Reason.to_string
      ( "This is why I think it is an object of type "
      ^ strip_ns (Cls.name class_) )
      r
  in
  let error hint =
    Errors.member_not_found kind pos cid member_name hint reason
  in
  let method_suggestion = Env.suggest_member is_method class_ member_name in
  let static_suggestion =
    Env.suggest_static_member is_method class_ member_name
  in
  match (method_suggestion, static_suggestion) with
  (* Prefer suggesting a different method, unless there's a
      static method whose name matches exactly. *)
  | (Some _, Some (def_pos, v)) when v = member_name ->
    error (`closest (def_pos, v))
  | (Some (def_pos, v), _) -> error (`did_you_mean (def_pos, v))
  | (None, Some (def_pos, v)) -> error (`closest (def_pos, v))
  | (None, None) when not (Cls.members_fully_known class_) ->
    (* no error in this case ... the member might be present
     * in one of the parents of class_ that the typing cannot see *)
    ()
  | (None, None) -> error `no_hint

(* Look up the type of the property or method id in the type ty1 of the
 * receiver and use the function k to postprocess the result.
 * Return any fresh type variables that were substituted for generic type
 * parameters in the type of the property or method.
 *
 * Essentially, if ty1 is a concrete type, e.g., class C, then k is applied
 * to the type of the property id in C; and if ty1 is an unresolved type,
 * e.g., a union of classes (C1 | ... | Cn), then k is applied to the type
 * of the property id in each Ci and the results are collected into an
 * unresolved type.
 *
 * The extra flexibility offered by the functional argument k is used in two
 * places:
 *
 *   (1) when type-checking method calls: if the receiver has an unresolved
 *   type, then we need to type-check the method call with each possible
 *   receiver type and collect the results into an unresolved type;
 *
 *   (2) when type-checking assignments to properties: if the receiver has
 *   an unresolved type, then we need to check that the right hand side
 *   value can be assigned to the property id for each of the possible types
 *   of the receiver.
 *)
let rec obj_get
    ~obj_pos
    ~is_method
    ~nullsafe
    ~coerce_from_ty
    ?(explicit_tparams = [])
    ?pos_params
    env
    ty1
    cid
    id =
  obj_get_
    ~inst_meth:false
    ~is_method
    ~nullsafe
    ~obj_pos
    ~pos_params
    ~explicit_tparams
    ~coerce_from_ty
    env
    ty1
    cid
    id
    (fun x -> x)

(* We know that the receiver is a concrete class: not a generic with
 * bounds, or a Tunion. *)
and obj_get_concrete_ty
    ~inst_meth
    ~is_method
    ~coerce_from_ty
    ?(explicit_tparams = [])
    env
    concrete_ty
    class_id
    (id_pos, id_str)
    k_lhs =
  let default () = (env, (Reason.Rwitness id_pos, Typing_utils.tany env)) in
  let mk_ety_env r class_info x e paraml =
    let this_ty = k_lhs (r, Tclass (x, e, paraml)) in
    {
      type_expansions = [];
      this_ty;
      substs = Subst.make_locl (Cls.tparams class_info) paraml;
      from_class = Some class_id;
    }
  in
  match concrete_ty with
  | (r, Tclass (x, exact, paraml)) ->
    let get_member_from_constraints env class_info =
      let ety_env = mk_ety_env r class_info x exact paraml in
      let upper_bounds =
        Sequence.to_list (Cls.upper_bounds_on_this class_info)
      in
      let (env, upper_bounds) =
        List.map_env env upper_bounds ~f:(fun env up ->
            Phase.localize ~ety_env env up)
      in
      let (env, inter_ty) =
        Inter.intersect_list env (Reason.Rwitness id_pos) upper_bounds
      in
      obj_get_
        ~inst_meth
        ~is_method
        ~nullsafe:None
        ~obj_pos:(Reason.to_pos r)
        ~pos_params:None
        ~explicit_tparams
        ~coerce_from_ty
        env
        inter_ty
        class_id
        (id_pos, id_str)
        k_lhs
    in
    begin
      match Env.get_class env (snd x) with
      | None -> default ()
      | Some class_info
        when (not is_method)
             && (not (Env.is_strict env))
             && (not (Partial.should_check_error (Env.get_mode env) 4053))
             && Cls.name class_info = SN.Classes.cStdClass ->
        default ()
      | Some class_info ->
        let paraml =
          if List.length paraml = 0 then
            List.map (Cls.tparams class_info) (fun _ ->
                (Reason.Rwitness id_pos, Typing_utils.tany env))
          else
            paraml
        in
        let old_member_info = Env.get_member is_method env class_info id_str in
        let self = Env.get_self_id env in
        let (member_info, shadowed) =
          if Cls.has_ancestor class_info self then
            (* We look up the current context to see if there is a field/method with
        * private visibility. If there is one, that one takes precedence *)
            match Env.get_class env self with
            | None -> (old_member_info, false)
            | Some self_class ->
              (match Env.get_member is_method env self_class id_str with
              | Some { ce_visibility = Vprivate _; _ } as member_info ->
                (member_info, true)
              | _ -> (old_member_info, false))
          else
            (old_member_info, false)
        in
        begin
          match member_info with
          | None when Cls.has_upper_bounds_on_this_from_constraints class_info
            ->
            Errors.try_with_result
              (fun () -> get_member_from_constraints env class_info)
              (fun _ _ ->
                member_not_found id_pos ~is_method class_info id_str r;
                default ())
          | None when not is_method ->
            if not (SN.Members.is_special_xhp_attribute id_str) then
              member_not_found id_pos ~is_method class_info id_str r;
            default ()
          | None ->
            begin
              match
                Env.get_member is_method env class_info SN.Members.__call
              with
              | None ->
                member_not_found id_pos ~is_method class_info id_str r;
                default ()
              | Some
                  {
                    ce_visibility = vis;
                    ce_type = (lazy (r, Tfun ft));
                    ce_deprecated;
                    _;
                  } ->
                let mem_pos = Reason.to_pos r in
                TVis.check_deprecated
                  ~use_pos:id_pos
                  ~def_pos:mem_pos
                  ce_deprecated;
                TVis.check_obj_access ~use_pos:id_pos ~def_pos:mem_pos env vis;

                (* the return type of __call can depend on the class params or be this *)
                let ety_env = mk_ety_env r class_info x exact paraml in
                (* TODO: possibly support coercion from dynamic in __call *)
                let (env, ft) =
                  Phase.(
                    localize_ft
                      ~instantiation:
                        {
                          use_pos = id_pos;
                          use_name = strip_ns id_str;
                          explicit_targs = [];
                        }
                      ~ety_env
                      ~def_pos:mem_pos
                      env
                      ft)
                in
                let arity_pos =
                  match ft.ft_params with
                  | [_; { fp_pos; fp_kind = FPnormal; _ }] -> fp_pos
                  (* we should really assert here but this is not yet validated *)
                  | _ -> mem_pos
                in
                (* we change the params of the underlying declaration to act as a
                 * variadic function ... this transform cannot be done when processing
                 * the declaration of call because direct calls to $inst->__call are also
                 * valid.
                 *)
                let ft =
                  {
                    ft with
                    ft_arity = Fellipsis (0, arity_pos);
                    ft_tparams = ([], FTKtparams);
                    ft_params = [];
                  }
                in
                let member_ty = (r, Tfun ft) in
                if inst_meth then
                  TVis.check_inst_meth_access
                    ~use_pos:id_pos
                    ~def_pos:mem_pos
                    vis;
                TVis.check_deprecated
                  ~use_pos:id_pos
                  ~def_pos:mem_pos
                  ce_deprecated;
                (env, member_ty)
              | _ -> assert false
            end
          (* match Env.get_member is_method env class_info SN.Members.__call *)
          | Some
              ( {
                  ce_visibility = vis;
                  ce_type = (lazy member_);
                  ce_abstract;
                  ce_xhp_attr;
                  ce_deprecated;
                  _;
                } as member_ce ) ->
            let mem_pos = Reason.to_pos (fst member_) in
            ( if shadowed then
              match old_member_info with
              | Some
                  { ce_visibility = old_vis; ce_type = (lazy old_member); _ }
                ->
                let old_mem_pos = Reason.to_pos (fst old_member) in
                begin
                  match class_id with
                  | CIexpr (_, This) when snd x = self -> ()
                  | _ ->
                    Errors.ambiguous_object_access
                      id_pos
                      id_str
                      mem_pos
                      (TUtils.string_of_visibility old_vis)
                      old_mem_pos
                      self
                      (snd x)
                end
              | _ -> () );
            TVis.check_obj_access ~use_pos:id_pos ~def_pos:mem_pos env vis;
            TVis.check_deprecated
              ~use_pos:id_pos
              ~def_pos:mem_pos
              ce_deprecated;
            if class_id = CIparent && ce_abstract then
              Errors.parent_abstract_call id_str id_pos mem_pos;
            let member_decl_ty = Typing_enum.member_type env member_ce in
            let ety_env = mk_ety_env r class_info x exact paraml in
            let (env, member_ty, et_enforced) =
              match member_decl_ty with
              | (r, Tfun ft) when is_method ->
                (* We special case function types here to be able to pass explicit type
                 * parameters. *)
                let explicit_targs =
                  List.map ~f:(Decl_hint.hint env.decl_env) explicit_tparams
                in
                let ft =
                  Typing_enforceability.compute_enforced_and_pessimize_fun_type
                    env
                    ft
                in
                let (env, ft) =
                  Phase.(
                    localize_ft
                      ~instantiation:
                        {
                          use_name = strip_ns id_str;
                          use_pos = id_pos;
                          explicit_targs;
                        }
                      ~ety_env
                      ~def_pos:mem_pos
                      env
                      ft)
                in
                (env, (r, Tfun ft), false)
              | _ ->
                let is_xhp_attr = Option.is_some ce_xhp_attr in
                let { et_type; et_enforced } =
                  Typing_enforceability.compute_enforced_and_pessimize_ty
                    env
                    member_decl_ty
                    ~is_xhp_attr
                in
                let (env, member_ty) = Phase.localize ~ety_env env et_type in
                (* TODO(T52753871): same as for class_get *)
                (env, member_ty, et_enforced)
            in
            if inst_meth then
              TVis.check_inst_meth_access ~use_pos:id_pos ~def_pos:mem_pos vis;
            let (env, member_ty) =
              if Cls.has_upper_bounds_on_this_from_constraints class_info then
                let ((env, ty), succeed) =
                  Errors.try_with_result
                    (fun () ->
                      (get_member_from_constraints env class_info, true))
                    (fun _ _ ->
                      (* No eligible functions found in constraints *)
                      ((env, MakeType.mixed Reason.Rnone), false))
                in
                if succeed then
                  let (env, member_ty) =
                    Inter.intersect env (Reason.Rwitness id_pos) member_ty ty
                  in
                  (env, member_ty)
                else
                  (env, member_ty)
              else
                (env, member_ty)
            in
            let env =
              match coerce_from_ty with
              | None -> env
              | Some (p, ur, ty) ->
                Typing_coercion.coerce_type
                  p
                  ur
                  env
                  ty
                  { et_type = member_ty; et_enforced }
                  Errors.unify_error
            in
            (env, member_ty)
        end
        (* match member_info *)
    end
  (* match Env.get_class env (snd x) *)
  | (_, Tdynamic) ->
    let ty = MakeType.dynamic (Reason.Rdynamic_prop id_pos) in
    (env, ty)
  | (_, Tobject)
  | (_, Tany _)
  | (_, Terr) ->
    default ()
  | (_, Tnonnull) ->
    Errors.top_member
      ~is_method
      ~is_nullable:false
      id_str
      id_pos
      (Typing_print.error env concrete_ty)
      (Reason.to_pos (fst concrete_ty));
    default ()
  | _ ->
    Errors.non_object_member
      ~is_method
      id_str
      id_pos
      (Typing_print.error env concrete_ty)
      (Reason.to_pos (fst concrete_ty));
    default ()

and widen_class_for_obj_get ~is_method ~nullsafe member_name env ty =
  match ty with
  | (_, Tprim Tnull) ->
    if Option.is_some nullsafe then
      (env, Some ty)
    else
      (env, None)
  | (r2, Tclass (((_, class_name) as class_id), _, tyl)) ->
    let default () =
      let ty = (r2, Tclass (class_id, Nonexact, tyl)) in
      (env, Some ty)
    in
    begin
      match Env.get_class env class_name with
      | None -> default ()
      | Some class_info ->
        (match Env.get_member is_method env class_info member_name with
        | Some { ce_origin; _ } ->
          (* If this member was inherited then we obtain the type from which
           * it is inherited as our wider type *)
          if ce_origin = class_name then
            default ()
          else (
            match Cls.get_ancestor class_info ce_origin with
            | None -> default ()
            | Some basety ->
              let ety_env =
                {
                  type_expansions = [];
                  substs = Subst.make_locl (Cls.tparams class_info) tyl;
                  this_ty = ty;
                  from_class = None;
                }
              in
              let (env, basety) = Phase.localize ~ety_env env basety in
              (env, Some basety)
          )
        | None -> (env, None))
    end
  | _ -> (env, None)

(* `ty` is expected to be the type for a property or method that has been
 * accessed using the nullsafe operatore e.g. $x?->prop or $x?->foo(...).
 *
 * For properties, just make the type nullable.
 * For methods, we expect a function type, and make the return type nullable.
 * But in the case that we have type dynamic, or err, or any, or nothing, we
 * just use the type `null`. The `call` helper will deal appropriately
 * with it.
 *)
and make_nullable_member_type env ~is_method id_pos pos ty =
  if is_method then
    match ty with
    | (r, Tfun tf) ->
      let (env, ty) =
        make_nullable_member_type
          ~is_method:false
          env
          id_pos
          pos
          tf.ft_ret.et_type
      in
      (env, (r, Tfun { tf with ft_ret = { tf.ft_ret with et_type = ty } }))
    | (r, Tunion (_ :: _ as tyl)) ->
      let (env, tyl) =
        List.map_env env tyl (fun env ty ->
            make_nullable_member_type ~is_method env id_pos pos ty)
      in
      Union.union_list env r tyl
    | (r, Tintersection tyl) ->
      let (env, tyl) =
        List.map_env env tyl (fun env ty ->
            make_nullable_member_type ~is_method env id_pos pos ty)
      in
      Inter.intersect_list env r tyl
    | (_, (Terr | Tdynamic | Tany _)) -> (env, ty)
    | (_, Tunion []) -> (env, MakeType.null (Reason.Rnullsafe_op pos))
    | _ ->
      (* Shouldn't happen *)
      make_nullable_member_type ~is_method:false env id_pos pos ty
  else
    let (env, ty) = Typing_solver.non_null env id_pos ty in
    (env, MakeType.nullable_locl (Reason.Rnullsafe_op pos) ty)

(* k_lhs takes the type of the object receiver *)
and obj_get_
    ~inst_meth
    ~is_method
    ~nullsafe
    ~obj_pos
    ~pos_params
    ~coerce_from_ty
    ?(explicit_tparams = [])
    env
    ty1
    cid
    ((id_pos, id_str) as id)
    k_lhs =
  let (env, ety1) =
    if is_method then
      Typing_solver.expand_type_and_solve
        env
        ~description_of_expected:"an object"
        obj_pos
        ty1
        Errors.unify_error
    else
      Typing_solver.expand_type_and_narrow
        env
        ~description_of_expected:"an object"
        (widen_class_for_obj_get ~is_method ~nullsafe id_str)
        obj_pos
        ty1
        Errors.unify_error
  in
  let nullable_obj_get ty =
    match nullsafe with
    | Some p1 ->
      let (env, method_) =
        obj_get_
          ~inst_meth
          ~obj_pos
          ~is_method
          ~nullsafe
          ~pos_params
          ~explicit_tparams
          ~coerce_from_ty
          env
          ty
          cid
          id
          k_lhs
      in
      make_nullable_member_type ~is_method env id_pos p1 method_
    | None ->
      (match ety1 with
      | (_, Toption (_, Tnonnull)) as ty ->
        Errors.top_member
          ~is_method
          ~is_nullable:true
          id_str
          id_pos
          (Typing_print.error env ty)
          (Reason.to_pos (fst ety1))
      | _ ->
        Errors.null_member
          ~is_method
          id_str
          id_pos
          (Reason.to_string "This can be null" (fst ety1)));
      (env, (fst ety1, Typing_utils.terr env))
  in
  match ety1 with
  | (_, Tunion tyl) ->
    let (env, tyl) =
      List.map_env env tyl (fun env ty ->
          obj_get_
            ~inst_meth
            ~obj_pos
            ~is_method
            ~nullsafe
            ~pos_params
            ~explicit_tparams
            ~coerce_from_ty
            env
            ty
            cid
            id
            k_lhs)
    in
    Union.union_list env (fst ety1) tyl
  | (_, Tintersection tyl) ->
    let (env, tyl) =
      TUtils.run_on_intersection env tyl ~f:(fun env ty ->
          obj_get_
            ~inst_meth
            ~obj_pos
            ~is_method
            ~nullsafe
            ~pos_params
            ~explicit_tparams
            ~coerce_from_ty
            env
            ty
            cid
            id
            k_lhs)
    in
    Inter.intersect_list env (fst ety1) tyl
  | (p', Tabstract (ak, Some ty)) ->
    let k_lhs' ty =
      match ak with
      | AKnewtype (_, _) -> k_lhs ty
      | _ -> k_lhs (p', Tabstract (ak, Some ty))
    in
    obj_get_
      ~inst_meth
      ~obj_pos
      ~is_method
      ~nullsafe
      ~pos_params
      ~explicit_tparams
      ~coerce_from_ty
      env
      ty
      cid
      id
      k_lhs'
  | (p', Tabstract (ak, _)) ->
    let resl =
      TUtils.try_over_concrete_supertypes env ety1 (fun env ty ->
          (* We probably don't want to rewrap new types for the 'this' closure *)
          (* TODO AKENN: we shouldn't refine constraints by changing
           * the type like this *)
          let k_lhs' ty =
            match ak with
            | AKnewtype (_, _) -> k_lhs ty
            | _ -> k_lhs (p', Tabstract (ak, Some ty))
          in
          obj_get_concrete_ty
            ~inst_meth
            ~is_method
            ~explicit_tparams
            ~coerce_from_ty
            env
            ty
            cid
            id
            k_lhs')
    in
    begin
      match resl with
      | [] ->
        Errors.non_object_member
          ~is_method
          id_str
          id_pos
          (Typing_print.error env ety1)
          (Reason.to_pos (fst ety1));
        (env, err_witness env id_pos)
      | ((_env, ty) as res) :: rest ->
        if List.exists rest (fun (_, ty') -> not @@ ty_equal ty' ty) then (
          Errors.ambiguous_member
            ~is_method
            id_str
            id_pos
            (Typing_print.error env ety1)
            (Reason.to_pos (fst ety1));
          (env, err_witness env id_pos)
        ) else
          res
    end
  | (_, Toption ty) -> nullable_obj_get ty
  | (r, Tprim Tnull) ->
    let ty = (r, Tunion []) in
    nullable_obj_get ty
  (* We are trying to access a member through a value of unknown type *)
  | (r, Tvar _) ->
    Errors.unknown_object_member
      ~is_method
      id_str
      id_pos
      (Reason.to_string "It is unknown" r);
    (env, (r, Typing_utils.terr env))
  | (_, _) ->
    obj_get_concrete_ty
      ~inst_meth
      ~is_method
      ~explicit_tparams
      ~coerce_from_ty
      env
      ety1
      cid
      id
      k_lhs
