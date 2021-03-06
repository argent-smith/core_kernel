open! Import

module Sexp = Sexplib.Sexp

include Sexp

include (Base.Sexp : module type of struct include Base.Sexp end with type t := t)

include (struct
  type t = Base.Sexp.t = Atom of string | List of t list [@@deriving bin_io]
end : sig
           type t [@@deriving bin_io]
         end with type t := t)

module O = struct
  type sexp = Sexp.t = Atom of string | List of t list
end

module Sexp_maybe = struct

  type sexp = t [@@deriving bin_io, compare, hash]             (* avoid recursive type *)

  (* to satisfy pa_compare *)
  module Error = struct
    include Error
    include Comparable.Poly (Error)
  end

  type 'a t = ('a, sexp * Error.t) Result.t [@@deriving bin_io, compare, hash]

  let sexp_of_t sexp_of_a t =
    match t with
    | Result.Ok a -> sexp_of_a a
    | Result.Error (sexp, err) ->
      Sexp.List [
        Sexp.Atom "sexp_parse_error";
        sexp;
        Error.sexp_of_t err;
      ]

  let t_of_sexp a_of_sexp sexp =
    match sexp with
    | Sexp.List [ Sexp.Atom "sexp_parse_error"; sexp; _ ]
    | sexp ->
      try Result.Ok (a_of_sexp sexp)
      with exn -> Result.Error (sexp, Error.of_exn exn)

end

module With_text = struct
  open Result.Export

  type 'a t =
    { value: 'a
    ; text: string
    }
  [@@deriving bin_io]

  let sexp_of_t _ t = Sexp.Atom t.text

  let of_text value_of_sexp ?(filename="") text =
    match
      Or_error.try_with (fun () ->
        Sexp.of_string_conv text value_of_sexp)
    with
    | Ok (`Result value) -> Ok { value; text }
    | Error _ as err -> err
    | Ok (`Error (exn, annotated)) ->
      Error (Error.of_exn (Sexp.Annotated.get_conv_exn annotated ~file:filename ~exc:exn))

  let t_of_sexp a_of_sexp sexp =
    match sexp with
    | List _ ->
      of_sexp_error
        "With_text.t should be stored as an atom, but instead a list was found." sexp
    | Atom text ->
      of_text a_of_sexp text |> Or_error.ok_exn

  let text  t = t.text
  let value t = t.value

  let of_value sexp_of_value value =
    let text = sexp_of_value value |> Sexp.to_string_hum in
    { value; text }

  let%test_module _ =
    (module struct
      let sexp_of_il = sexp_of_list sexp_of_int
      let il_of_sexp = list_of_sexp int_of_sexp

      let il_of_text text = Or_error.ok_exn (of_text il_of_sexp text)
      let il_of_value il  = of_value sexp_of_il il

      let t = il_of_value [3;4]
      let%test _ = String.equal t.text "(3 4)"
      let t' = il_of_text (text t)
      let%test _ = [%compare.equal: int list] t'.value [3;4]
      let%test _ = sexp_of_t sexp_of_il t = Atom "(3 4)"
      let%test _ =
        [%compare.equal: int list] (t_of_sexp il_of_sexp (Atom "(3 4)")).value [3;4]

      let%test _ =
        [%compare.equal: int list] [8;9]
          (il_of_text ";this is a comment\n (8; foo\n 9)   \n ").value

      let check_error f input ~expected =
        let normalize str = try Sexp.to_string (Sexp.of_string str) with _ -> str in
        let expected = normalize expected in
        try
          ignore (f input);
          failwith
            (Printf.sprintf "%s expected to cause an exception, \
                             but got converted successfully." input)
        with e ->
          let error = normalize (Exn.to_string e) in
          if not (String.equal error expected) then
            failwith (Printf.sprintf "%s generated error %s, expected %s"
                        input error expected)

      let expected =
        "(Sexplib.Conv.Of_sexp_error(
        Sexplib.Sexp.Annotated.Conv_exn
        :1:5(Failure\"int_of_sexp: (Failure int_of_string)\"))bla)"

      let%test_unit _ =
        check_error il_of_text
          "(1 2 bla)" ~expected

      let%test_unit _ =
        check_error (fun s -> t_of_sexp il_of_sexp (Sexp.of_string s))
          "\"(1 2 bla)\"" ~expected
    end)
end

type 'a no_raise = 'a [@@deriving bin_io, sexp]

let sexp_of_no_raise sexp_of_a a =
  try sexp_of_a a
  with exn ->
  try List [ Atom "failure building sexp"; sexp_of_exn exn ]
  with _ -> Atom "could not build sexp for exn raised when building sexp for value"
;;

include Comparable.Extend(Base.Sexp)(Base.Sexp)

let of_sexp_allow_extra_fields of_sexp sexp =
  let r = Sexplib.Conv.record_check_extra_fields in
  let prev = !r in
  Exn.protect ~finally:(fun () -> r := prev)
    ~f:(fun () -> r := false; of_sexp sexp)

module For_quickcheck = struct

  module Generator = Quickcheck.Generator
  module Observer  = Quickcheck.Observer
  module Shrinker  = Quickcheck.Shrinker

  open Generator.Let_syntax

  let gen =
    Generator.recursive (fun self ->
      let%bind size = Generator.size in
      (* choose a number weighted low so we have a decreasing, but not vanishing, chance
         to generate atoms as size grows *)
      match%bind Int.gen_log_uniform_incl 0 (size + 1) with
      (* generate a non-empty string based on the given size *)
      | 0 -> let%map atom = String.gen    in Atom atom
      (* relying on [List.gen] to distribute [size] over sub-sexps *)
      | _ -> let%map list = List.gen self in List list)

  let obs =
    Observer.recursive (fun t_obs ->
      Observer.unmap
        (Observer.variant2
           String.obs
           (List.obs t_obs))
        ~f:(function
          | Sexp.Atom atom -> `A atom
          | Sexp.List list -> `B list))

  let shrinker =
    let open Sequence.Monad_infix in
    Shrinker.recursive (fun shrinker ->
      Shrinker.create (function
        | Sexp.Atom _    -> Sequence.empty
        | Sexp.List list ->
          let shrink_list =
            Shrinker.shrink (List.shrinker shrinker) list
            >>| fun l -> Sexp.List l
          in
          let shrink_tree = Sequence.of_list list in
          Sequence.interleave (Sequence.of_list [ shrink_list; shrink_tree ])))

end

let gen      = For_quickcheck.gen
let obs      = For_quickcheck.obs
let shrinker = For_quickcheck.shrinker
