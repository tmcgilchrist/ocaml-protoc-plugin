open StdLabels

module S = Spec.Serialize
module C = S.C
open S

let field_type: type a. a spec -> int = function
  | Int64 | UInt64 | SInt64 | Int32 | UInt32 | SInt32
  | Int64_int | UInt64_int | Int32_int | UInt32_int | SInt64_int | SInt32_int
  | Bool | Enum _ -> 0 (* Varint *)
  | String | Bytes | Message _ -> 2 (* Length delimited *)
  | Double | Fixed64 | SFixed64 | Fixed64_int | SFixed64_int -> 1 (* Fixed 64 bit *)
  | Float | Fixed32 | SFixed32 | Fixed32_int | SFixed32_int -> 5 (* Fixed 32 bit *)

let write_fixed64 ~f v =
  Writer.write_fixed64_value (f v)

let write_fixed32 ~f v =
  Writer.write_fixed32_value (f v)

let zigzag_encoding v =
  let open Infix.Int64 in
  let v = match v < 0L with
    | true -> v lsl 1 lxor (-1L)
    | false -> v lsl 1
  in
  v

let zigzag_encoding_unboxed v =
  let v = match v < 0 with
    | true -> v lsl 1 lxor (-1)
    | false -> v lsl 1
  in
  v

let write_varint ~f v =
  Writer.write_varint_value (f v)

let write_varint_unboxed ~f v =
  Writer.write_varint_unboxed_value (f v)

let write_length_delimited_string ~f v =
  let v = f v in
  Writer.write_length_delimited_value ~data:v ~offset:0 ~len:(String.length v)

let id x = x
let (@@) a b = fun v -> b (a v)

let write_value : type a. a spec -> a -> Writer.t -> unit = function
  | Double -> write_fixed64 ~f:Int64.bits_of_float
  | Float -> write_fixed32 ~f:Int32.bits_of_float
  | Fixed64 -> write_fixed64 ~f:id
  | SFixed64 -> write_fixed64 ~f:id
  | Fixed64_int -> write_fixed64 ~f:Int64.of_int
  | SFixed64_int -> write_fixed64 ~f:Int64.of_int
  | Fixed32 -> write_fixed32 ~f:id
  | SFixed32 -> write_fixed32 ~f:id
  | Fixed32_int -> write_fixed32 ~f:Int32.of_int
  | SFixed32_int -> write_fixed32 ~f:Int32.of_int
  | Int64 -> write_varint ~f:id
  | UInt64 -> write_varint ~f:id
  | SInt64 -> write_varint ~f:zigzag_encoding
  | Int32 -> write_varint_unboxed ~f:Int32.to_int
  | UInt32 -> write_varint_unboxed ~f:Int32.to_int
  | SInt32 -> write_varint_unboxed ~f:(Int32.to_int @@ zigzag_encoding_unboxed)
  | Int64_int -> write_varint_unboxed ~f:id
  | UInt64_int -> write_varint_unboxed ~f:id
  | Int32_int -> write_varint_unboxed ~f:id
  | UInt32_int -> write_varint_unboxed ~f:id
  | SInt64_int -> write_varint_unboxed ~f:zigzag_encoding_unboxed
  | SInt32_int -> write_varint_unboxed ~f:zigzag_encoding_unboxed

  | Bool -> write_varint_unboxed ~f:(function true -> 1 | false -> 0)
  | String -> write_length_delimited_string ~f:id
  | Bytes -> write_length_delimited_string ~f:Bytes.unsafe_to_string
  | Enum f -> write_varint_unboxed ~f
  | Message to_proto ->
    Writer.write_length_delimited_f ~write_f:to_proto

(** Optimized when the value is given in advance, and the continuation is expected to be called multiple times *)
let write_value_const : type a. a spec -> a -> Writer.t -> unit = fun spec v ->
  let write_value = write_value spec in
  let writer = Writer.init () in
  write_value v writer;
  let data = Writer.contents writer in
  Writer.write_const_value data

let write_field_header: 'a spec -> int -> Writer.t -> unit = fun spec index ->
  let field_type = field_type spec in
  let header = (index lsl 3) + field_type in
  write_value_const Int64_int header

let write_field: type a. a spec -> int -> Writer.t -> a -> unit = fun spec index ->
  let write_field_header = write_field_header spec index in
  let write_value = write_value spec in
  fun writer v->
    write_field_header writer;
    write_value v writer

let rec write: type a. a compound -> Writer.t -> a -> unit = function
  | Repeated (index, spec, Packed) -> begin
      let write_value = write_value spec in
      let write_f writer vs = List.iter ~f:(fun v -> write_value v writer) vs; writer in
      let write_header = write_field_header String index in
      fun writer vs ->
        match vs with
        | [] -> ()
        | vs ->
          write_header writer;
          Writer.write_length_delimited_f ~write_f vs writer
    end
  | Repeated (index, spec, Not_packed) ->
    let write = write_field spec index in
    fun writer vs ->
      List.iter ~f:(fun v -> write writer v) vs
  | Basic (index, spec, default) -> begin
      let write = write_field spec index in
      let writer writer = function
        | v when v = default -> ()
        | v -> write writer v
      in
      writer
    end
  | Basic_req (index, spec) ->
      write_field spec index
  | Basic_opt (index, spec) -> begin
      let write = write_field spec index in
      fun writer v ->
        match v with
        | Some v -> write writer v
        | None -> ()
  end
  | Oneof f -> begin
      fun writer v ->
        match v with
        | `not_set -> ()
        | v ->
          let Oneof_elem (index, spec, v) = f v in
          write (Basic_req (index, spec)) writer v
    end

let in_extension_ranges extension_ranges index =
  List.exists ~f:(fun (start, end') -> index >= start && index <= end') extension_ranges

let rec serialize : type a. (a, Writer.t) compound_list -> Writer.t -> a = function
  | Nil -> fun writer -> writer
  | Nil_ext extension_ranges ->
    fun writer extensions ->
      List.iter ~f:(function
        | (index, field) when in_extension_ranges extension_ranges index -> Writer.write_field writer index field
        | _ -> ()
      ) extensions;
      writer
  | Cons (compound, rest) ->
    let cont = serialize rest in
    let write = write compound in
    fun writer v ->
      write writer v;
      cont writer

let%expect_test "zigzag encoding" =
  let test vl =
    let v = Int64.to_int vl in
    Printf.printf "zigzag_encoding(%LdL) = %LdL\n" vl (zigzag_encoding vl);
    Printf.printf "zigzag_encoding_unboxed(%d) = %d\n" v (zigzag_encoding_unboxed v);
  in
  List.iter ~f:test [0L; -1L; 1L; -2L; 2L; 2147483647L; -2147483648L; Int64.max_int; Int64.min_int; ];
  [%expect {|
    zigzag_encoding(0L) = 0L
    zigzag_encoding_unboxed(0) = 0
    zigzag_encoding(-1L) = 1L
    zigzag_encoding_unboxed(-1) = 1
    zigzag_encoding(1L) = 2L
    zigzag_encoding_unboxed(1) = 2
    zigzag_encoding(-2L) = 3L
    zigzag_encoding_unboxed(-2) = 3
    zigzag_encoding(2L) = 4L
    zigzag_encoding_unboxed(2) = 4
    zigzag_encoding(2147483647L) = 4294967294L
    zigzag_encoding_unboxed(2147483647) = 4294967294
    zigzag_encoding(-2147483648L) = 4294967295L
    zigzag_encoding_unboxed(-2147483648) = 4294967295
    zigzag_encoding(9223372036854775807L) = -2L
    zigzag_encoding_unboxed(-1) = 1
    zigzag_encoding(-9223372036854775808L) = -1L
    zigzag_encoding_unboxed(0) = 0 |}]
