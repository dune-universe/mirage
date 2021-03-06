(*
 * Copyright (c) 2015 Gabriel Radanne <drupyog@zoho.com>
 * Copyright (c) 2015-2020 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let src = Logs.Src.create "functoria" ~doc:"functoria library"

module Log = (val Logs.src_log src : Logs.LOG)

open Rresult
open Astring

type t = JOB

let t = Type.v JOB

(* Noop, the job that does nothing. *)
let noop = Impl.v "Unit" t

module Keys = struct
  let with_output f k =
    Bos.OS.File.with_oc f k ()
    >>= R.reword_error_msg (fun _ ->
            `Msg (Fmt.strf "couldn't open output channel %a" Fpath.pp f))

  let configure ~file i =
    Log.info (fun m -> m "Generating: %a" Fpath.pp file);
    with_output file (fun oc () ->
        let fmt = Format.formatter_of_out_channel oc in
        Codegen.append fmt "(* %s *)" (Codegen.generated_header ());
        Codegen.newline fmt;
        let keys = Key.Set.of_list @@ Info.keys i in
        let pp_var k = Key.serialize (Info.context i) k in
        Fmt.pf fmt "@[<v>%a@]@." (Fmt.iter Key.Set.iter pp_var) keys;
        let runvars = Key.Set.elements (Key.filter_stage `Run keys) in
        let pp_runvar ppf v = Fmt.pf ppf "%s_t" (Key.ocaml_name v) in
        let pp_names ppf v = Fmt.pf ppf "%S" (Key.name v) in
        Codegen.append fmt "let runtime_keys = List.combine %a %a"
          Fmt.Dump.(list pp_runvar)
          runvars
          Fmt.Dump.(list pp_names)
          runvars;
        Codegen.newline fmt;
        Ok ())

  let clean ~file _ = Bos.OS.Path.delete file
end

let keys (argv : Argv.t Impl.t) =
  let packages = [ Package.v "functoria-runtime" ] in
  let extra_deps = [ Impl.abstract argv ] in
  let module_name = Key.module_name in
  let file = Fpath.(v (String.Ascii.lowercase module_name) + "ml") in
  let configure = Keys.configure ~file and clean = Keys.clean ~file in
  let connect info impl_name = function
    | [ argv ] ->
        Fmt.strf
          "return (Functoria_runtime.with_argv (List.map fst %s.runtime_keys) \
           %S %s)"
          impl_name (Info.name info) argv
    | _ -> failwith "The keys connect should receive exactly one argument."
  in
  Impl.v ~configure ~clean ~packages ~extra_deps ~connect module_name t
