(** A buffer for incremental decoding of an input stream.

    An [Unpack_buffer.t] is a buffer to which one can [feed] strings, and then [unpack]
    from the buffer to produce a queue of values.
*)

open! Import

open Std_internal

module Unpack_one : sig
  (** If [unpack_one : ('a, 'partial_unpack) unpack_one], then [unpack_one buf ?pos
      ?len ?partial_unpack] must unpack at most one value of type ['a] from [buf]
      starting at [pos], and not using more than [len] characters.  [unpack_one] must
      returns one the following:

      - [`Ok (value, n)] -- unpacking succeeded and consumed [n] bytes, where [0 <= n <=
      len].  It is possible to have [n = 0], e.g. for sexp unpacking, which can only tell
      it has reached the end of an atom when it encounters the following punctuation
      character, which if it is left paren, is the start of the following sexp.

      - [`Not_enough_data (p, n)] -- unpacking encountered a valid proper prefix of a
      packed value, and consumed [n] bytes, where [0 <= n <= len].  [p] is a "partial
      unpack" that can be supplied to a future call to [unpack_one] to continue unpacking.

      - [`Invalid_data] -- unpacking encountered an invalidly packed value.

      A naive [unpack_one] that only succeeds on a fully packed value could lead to
      quadratic behavior if a packed value's bytes are input using a linear number of
      calls to [feed]. *)

  type ('a, 'partial_unpack) unpacked =
    ?partial_unpack : 'partial_unpack
    -> ?pos         : int  (** default is [0] *)
    -> ?len         : int  (** default is [Bigstring.len bigstring - pos] *)
    -> Bigstring.t
    -> [ `Ok              of 'a * int
       | `Not_enough_data of 'partial_unpack * int
       | `Invalid_data    of Error.t
       ]

  type 'a t = T : ('a, _) unpacked -> 'a t

  include Monad.S with type 'a t := 'a t

  (** [create_bin_prot reader] returns an unpacker that reads the "size-prefixed" bin_prot
      encoding, in which a value is encoded by first writing the length of the bin_prot
      data as a 64-bit int, and then writing the data itself.  This encoding makes it
      trivial to know if enough data is available in the buffer, so there is no need to
      represent partially unpacked values, and hence ['partial_unpack = unit]. *)
  val create_bin_prot : 'a Bin_prot.Type_class.reader -> 'a t

  (** Beware that when unpacking sexps, one cannot tell if one is at the end of an atom
      until one hits punctuation.  So, one should always feed a space (" ") to a sexp
      unpack buffer after feeding a batch of complete sexps, to ensure that the final sexp
      is unpacked. *)
  val sexp : Sexp.t t

  val char : char t

  module type Equal = sig
    type t [@@deriving sexp_of]
    val equal : t -> t -> bool
  end

  (** [expect t equal a] returns an unpacker that unpacks using [t] and then returns [`Ok]
      if the unpacked value equals [a], or [`Invalid_data] otherwise. *)
  val expect : 'a t -> (module Equal with type t = 'a) -> 'a -> unit t

  (** [expect_char] is [expect char (module Char)] *)
  val expect_char : char -> unit t

  val newline : unit t
end

type 'a t [@@deriving sexp_of]

include Invariant.S1 with type 'a t := 'a t

val create : 'a Unpack_one.t -> 'a t

val create_unpacked
  :  ?partial_unpack : 'partial_unpack
  -> ('a, 'partial_unpack) Unpack_one.unpacked
  -> 'a t

(** [create_bin_prot reader] returns an unpack buffer that unpacks the "size-prefixed"
    bin_prot encoding, in which a value is encoded by first writing the length of the
    bin_prot data as a 64-bit int, and then writing the bin_prot data itself. *)
val create_bin_prot : 'a Bin_prot.Type_class.reader -> 'a t

(** [is_empty t] returns [true] if [t] has no unconsumed bytes, and [false] if it does.
    [is_empty] returns an error if [t] has encountered an unpacking error. *)
val is_empty : _ t -> bool Or_error.t

(** [feed t buf ?pos ?len] adds the specified substring of [buf] to [t]'s buffer.  It
    returns an error if [t] has encountered an unpacking error. *)
val feed        : ?pos:int -> ?len:int -> _ t -> Bigstring.t -> unit Or_error.t
val feed_string : ?pos:int -> ?len:int -> _ t -> string      -> unit Or_error.t
val feed_bytes  : ?pos:int -> ?len:int -> _ t -> Bytes.t     -> unit Or_error.t

(** [unpack_into t q] unpacks all the values that it can from [t] and enqueues them in
    [q].  If there is an unpacking error, [unpack_into] returns an error, and subsequent
    [feed] and unpack operations on [t] will return that same error -- i.e. no more data
    can be fed to or unpacked from [t]. *)
val unpack_into : 'a t -> 'a Queue.t -> unit Or_error.t

(** [unpack_iter t ~f] unpacks all the values that it can from [t], calling [f] on each
    value as it's unpacked.  If there is an unpacking error (including if [f] raises),
    [unpack_iter] returns an error, and subsequent [feed] and unpack operations on [t]
    will return that same error -- i.e. no more data can be fed to or unpacked from [t].

    Behavior is unspecified if [f] operates on [t]. *)
val unpack_iter : 'a t -> f:('a -> unit) -> unit Or_error.t

(** [debug] controls whether invariants are checked at each call.  Setting this to [true]
    can make things very slow. *)
val debug : bool ref
