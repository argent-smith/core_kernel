include module type of struct include Base.Int64 end
  with module Hex := Base.Int64.Hex

include Int_intf.Extension
  with type t := t
   and type comparator_witness := comparator_witness
