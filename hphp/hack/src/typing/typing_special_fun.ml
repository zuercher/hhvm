(*
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Core_kernel
open Typing_defs
module SN = Naming_special_names
module MakeType = Typing_make_type
module TUtils = Typing_utils

let update_param p ty = { p with fp_type = { p.fp_type with et_type = ty } }

(* Given a decl function type that was obtained from an hhi file,
 * transform it for special functions such as `idx` and `array_map`
 * according to the number of arguments actually passed to the function
 *)
let transform_special_fun_ty fty id nargs =
  (* The idx function has two signatures, depending on number of arguments
   * actually passed:
   *
   * idx<Tk as arraykey, Tv>(?KeyedContainer<Tk, ?Tv> $collection, ?Tk $index): ?Tv
   * idx<Tk as arraykey, Tv>(?KeyedContainer<Tk, Tv> $collection, ?Tk $index, Tv $default): Tv
   *
   * In the hhi file, it has signature
   *
   * function idx<Tk as arraykey, Tv>
   *   (?KeyedContainer<Tk, Tv> $collection, ?Tk $index, $default = null)
   *
   * so this needs to be munged into the above.
   *)
  if String.equal (snd id) SN.FB.idx then
    let (param1, param2, param3) =
      match fty.ft_params with
      | [param1; param2; param3] -> (param1, param2, param3)
      | _ -> failwith "Expected 3 parameters for idx in hhi file"
    in
    let r3 = fst param1.fp_type.et_type in
    let rret = fst fty.ft_ret.et_type in
    let (params, ret) =
      match nargs with
      | 2 ->
        (* Transform ?KeyedContainer<Tk, Tv> to ?KeyedContainer<Tk, ?Tv> *)
        let ty1 =
          match param1.fp_type.et_type with
          | (r11, Toption (r12, Tapply (coll, [tk; ((r13, _) as tv)]))) ->
            (r11, Toption (r12, Tapply (coll, [tk; (r13, Toption tv)])))
          | _ -> failwith "Wrong type for idx in hhi file"
        in
        let param1 = update_param param1 ty1 in
        (* Return type should be ?Tv *)
        let ret = MakeType.nullable_decl rret (rret, Tgeneric "Tv") in
        ([param1; param2], ret)
      | 3 ->
        (* Third parameter should have type Tv *)
        let param3 = update_param param3 (r3, Tgeneric "Tv") in
        (* Return type should be Tv *)
        let ret = (rret, Tgeneric "Tv") in
        ([param1; param2; param3], ret)
      (* Shouldn't happen! *)
      | _ -> (fty.ft_params, fty.ft_ret.et_type)
    in
    { fty with ft_params = params; ft_ret = { fty.ft_ret with et_type = ret } }
  else if
    (*
      Builds a function with signature:

      function<T1, ..., Tn, Tr>(
        (function(T1, ..., Tn):Tr),
        Container<T1>,
        ...,
        Container<Tn>,
      ): array<Tr>

      where n is one fewer than the actual number of arguments. The hhi
      file just has the untyped declaration

      function array_map($callback, $arr1, ...$args);
    *)
    String.equal (snd id) SN.StdlibFunctions.array_map && nargs > 0
  then
    let arity = nargs - 1 in
    if arity = 0 then
      fty
    else
      let (param1, param2) =
        match fty.ft_params with
        | param1 :: param2 :: _ -> (param1, param2)
        | _ -> assert false
      in
      let r1 = fst param1.fp_type.et_type in
      let r2 = fst param2.fp_type.et_type in
      let rret = fst fty.ft_ret.et_type in
      let tr = (rret, Tgeneric "Tr") in
      let rec make_tparam_names i =
        if i = 0 then
          []
        else
          ("T" ^ string_of_int i) :: make_tparam_names (i - 1)
      in
      let tparam_names = List.rev (make_tparam_names arity) in
      let vars = List.map tparam_names (fun name -> (r2, Tgeneric name)) in
      let make_tparam name =
        {
          tp_variance = Ast_defs.Invariant;
          tp_name = (fst id, name);
          tp_constraints = [];
          tp_reified = Aast.Erased;
          tp_user_attributes = [];
        }
      in
      let ft_tparams =
        (List.map tparam_names make_tparam @ [make_tparam "Tr"], FTKtparams)
      in
      (* Construct type of first parameter *)
      let param1 =
        update_param
          param1
          ( r1,
            Tfun
              {
                ft_is_coroutine = false;
                ft_arity = Fstandard (arity, arity);
                ft_tparams = ([], FTKtparams);
                ft_where_constraints = [];
                ft_params = List.map vars TUtils.default_fun_param;
                ft_ret = MakeType.unenforced tr;
                ft_fun_kind = fty.ft_fun_kind;
                ft_reactive = fty.ft_reactive;
                ft_mutability = fty.ft_mutability;
                ft_returns_mutable = fty.ft_returns_mutable;
                ft_return_disposable = fty.ft_return_disposable;
                ft_returns_void_to_rx = fty.ft_returns_void_to_rx;
              } )
      in
      let param_rest =
        List.map vars (fun var ->
            let tc = Tapply ((fst id, SN.Collections.cContainer), [var]) in
            TUtils.default_fun_param (r2, tc))
      in
      {
        fty with
        ft_arity = Fstandard (arity + 1, arity + 1);
        ft_params = param1 :: param_rest;
        ft_tparams;
        ft_ret = MakeType.unenforced (rret, Tarray (Some tr, None));
      }
  else
    fty
