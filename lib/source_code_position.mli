open Sexplib

type t = Lexing.position with bin_io, sexp

type t_hum = t with bin_io, compare, sexp_of

include Comparable.S with type t := t
include Hashable.S   with type t := t

val to_string : t -> string

