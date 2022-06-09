(******************************************************************************)
(*                                                                            *)
(*     Alt-Ergo: The SMT Solver For Software Verification                     *)
(*     Copyright (C) 2013-2017 --- OCamlPro SAS                               *)
(*                                                                            *)
(*     This file is distributed under the terms of the license indicated      *)
(*     in the file 'License.OCamlPro'. If 'License.OCamlPro' is not           *)
(*     present, please contact us to clarify licensing.                       *)
(*                                                                            *)
(******************************************************************************)

(** A wrapper of the Dynlink module: we use Dynlink except when we want to
generate a static (native) binary **)

module DummyDL = struct

  type error = string

  exception Error of error

  let error_message s = s

  let loadfile s = ()

end

include Dynlink
