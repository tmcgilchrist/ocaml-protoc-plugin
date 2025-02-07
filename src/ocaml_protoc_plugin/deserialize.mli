module C = Spec.Deserialize.C

val deserialize:
  ('constr, 'a) Spec.Deserialize.compound_list ->
  'constr -> Reader.t -> 'a

(** **)
val deserialize_full:
  ('constr, 'a) Spec.Deserialize.compound_list ->
  'constr -> Reader.t -> 'a

val deserialize_fast:
  ('constr, 'a) Spec.Deserialize.compound_list ->
  'constr -> Reader.t -> 'a
(** **)
