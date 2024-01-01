open StdLabels
type t = (int * Field.t) list
let default = []
let pp_item fmt (index, field) = Format.fprintf fmt "(%d, %a)" index Field.pp field
let pp : Format.formatter -> t -> unit = fun fmt -> Format.pp_print_list pp_item fmt
let show : t -> string = Format.asprintf "%a" pp
let equal _ _ = true
let compare _ _ = 0

let get: ('b -> 'b, 'b) Deserialize.S.compound_list -> t -> 'b = fun spec t ->
  let writer = Writer.of_list t in
  let reader = Writer.contents writer |> Reader.create in
  Deserialize.deserialize [] spec (fun _ a -> a) reader

let set: ('a -> Writer.t, Writer.t) Serialize.S.compound_list -> t -> 'a -> t = fun spec t v ->
  let writer = Writer.init () in
  let writer = Serialize.serialize [] spec [] writer v in
  let reader = Writer.contents writer |> Reader.create in
  match Reader.to_list reader with
  | (((index, _) :: _) as fields) ->
    (List.filter ~f:(fun (i, _) -> i != index) t) @  fields
  | [] -> t
  | exception Result.Error _ -> failwith "Internal serialization fail"
