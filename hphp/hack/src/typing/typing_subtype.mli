module Env = Typing_env
open Typing_defs
open Typing_env_types

type reactivity_extra_info = {
  method_info: (* method_name *) (string * (* is_static *) bool) option;
  class_ty: phase_ty option;
  parent_class_ty: phase_ty option;
}

module ConditionTypes : sig
  val try_get_class_for_condition_type :
    env ->
    decl_ty ->
    ((Ast_defs.pos * string) * Decl_provider.class_decl) option

  val try_get_method_from_condition_type :
    env -> decl_ty -> bool -> string -> class_elt option

  val localize_condition_type : env -> decl_ty -> locl_ty
end

val is_sub_type_LEGACY_DEPRECATED : env -> locl_ty -> locl_ty -> bool

(** Non-side-effecting test for subtypes.
    result = true implies ty1 <: ty2
    result = false implies NOT ty1 <: ty2 OR we don't know
*)
val is_sub_type : env -> locl_ty -> locl_ty -> bool

val is_sub_type_ignore_generic_params : env -> locl_ty -> locl_ty -> bool

val is_sub_type_for_union : env -> locl_ty -> locl_ty -> bool

val can_sub_type : env -> locl_ty -> locl_ty -> bool

(**
  Checks that ty_sub is a subtype of ty_super, and returns an env.

  E.g.
    sub_type env ?int int   => env
    sub_type env int alpha  => env where alpha==int
    sub_type env ?int alpha => env where alpha==?int
    sub_type env int string => error
 *)
val sub_type : env -> locl_ty -> locl_ty -> Errors.typing_error_callback -> env

val sub_type_with_dynamic_as_bottom :
  env -> locl_ty -> locl_ty -> Errors.typing_error_callback -> env

val sub_type_i :
  env -> internal_type -> internal_type -> Errors.typing_error_callback -> env

(** Check that the method with signature ft_sub can be used to override
(is a subtype of) method with signature ft_super. *)
val subtype_method :
  check_return:bool ->
  extra_info:reactivity_extra_info ->
  env ->
  Reason.t ->
  decl_fun_type ->
  Reason.t ->
  decl_fun_type ->
  Errors.typing_error_callback ->
  env

val subtype_reactivity :
  ?extra_info:reactivity_extra_info ->
  ?is_call_site:bool ->
  env ->
  reactivity ->
  reactivity ->
  bool

val add_constraint :
  Pos.t -> env -> Ast_defs.constraint_kind -> locl_ty -> locl_ty -> env

val log_prop : env -> unit

val add_tyvar_upper_bound_and_close :
  env -> int -> internal_type -> Errors.typing_error_callback -> env

val add_tyvar_lower_bound_and_close :
  env -> int -> internal_type -> Errors.typing_error_callback -> env
