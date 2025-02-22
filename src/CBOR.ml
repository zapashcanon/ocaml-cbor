(** CBOR encoder/decoder, RFC 7049 *)

open Printf
module BE = EndianBytes.BigEndian_unsafe
module SE = EndianString.BigEndian_unsafe

exception Error of string

let (@@) f x = f x
let (|>) x f = f x
let list_iteri f l = let i = ref 0 in List.iter (fun x -> f !i x; incr i) l
let fail fmt = ksprintf (fun s -> raise (Error s)) fmt

module Encode = struct

let start () = Buffer.create 10

let init b ~maj add =
  assert (maj >= 0 && maj < 8);
  assert (add >= 0 && add < 32);
  Buffer.add_char b @@ char_of_int @@ (maj lsl 5) lor add

let put_n b n f x =
  let s = Bytes.create n in
  f s 0 x;
  Buffer.add_string b (Bytes.unsafe_to_string s)

let put b ~maj n =
  assert (n >= 0);
  if n < 24 then
    init b ~maj n
  else if n < 256 then
    begin init b ~maj 24; Buffer.add_char b @@ char_of_int n end
  else if n < 65536 then
    begin init b ~maj 25; put_n b 2 BE.set_int16 n end
  else if n < 4294967296 then (* optcomp int32 *)
    begin init b ~maj 26; put_n b 4 BE.set_int32 @@ Int32.of_int n end
  else
    begin init b ~maj 27; put_n b 8 BE.set_int64 @@ Int64.of_int n end

let int b n =
  let (maj,n) = if n < 0 then 1, -1 - n else 0, n in
  put b ~maj n

let hex_char x =
  assert (x >= 0 && x < 16);
  if x <= 9 then Char.chr @@ Char.code '0' + x
  else Char.chr @@ Char.code 'a' + x - 10

let to_hex s =
  let r = Bytes.create (String.length s * 2) in
  for i = 0 to String.length s - 1 do
    Bytes.set r (i * 2) (hex_char @@ Char.code s.[i] lsr 4);
    Bytes.set r (i * 2 + 1) (hex_char @@ Char.code s.[i] land 0b1111);
  done;
  Bytes.to_string r

end

module Simple = struct

type t =
[ `Null
| `Undefined
| `Simple of int
| `Bool of bool
| `Int of int
| `Float of float
| `Bytes of string
| `Text of string
| `Array of t list
| `Map of (t * t) list
]

let encode item =
  let open Encode in
  let b = start () in
  let rec write = function
  | `Null -> put b ~maj:7 22;
  | `Undefined -> put b ~maj:7 23;
  | `Bool false -> put b ~maj:7 20;
  | `Bool true -> put b ~maj:7 21;
  | `Simple n when (n >= 0 && n <= 23) || (n >= 32 && n <= 255) -> put b ~maj:7 n
  | `Simple n -> fail "encode: simple(%d)" n
  | `Int n -> int b n
  | `Float f -> init b ~maj:7 27; put_n b 8 BE.set_double f
  | `Bytes s -> put b ~maj:2 (String.length s); Buffer.add_string b s
  | `Text s -> put b ~maj:3 (String.length s); Buffer.add_string b s
  | `Array l -> put b ~maj:4 (List.length l); List.iter write l
  | `Map m -> put b ~maj:5 (List.length m); List.iter (fun (a,b) -> write a; write b) m
  in
  write item;
  Buffer.contents b

let need (s,i) n =
  if n > String.length s || !i + n > String.length s then
    fail "truncated: len %d pos %d need %d" (String.length s) !i n;
  let j = !i in
  i := !i + n;
  j

let get_byte (s,_ as r) = int_of_char @@ s.[need r 1]
let get_n (s,_ as r) n f = f s @@ need r n
let get_s (s,_ as r) n = String.sub s (need r n) n

let get_additional byte1 = byte1 land 0b11111
let is_indefinite byte1 = get_additional byte1 = 31

let int64_max_int = Int64.of_int max_int
let two_min_int32 = 2 * Int32.to_int Int32.min_int

let extract_number byte1 r =
  match get_additional byte1 with
  | n when n < 24 -> n
  | 24 -> get_byte r
  | 25 -> get_n r 2 SE.get_uint16
  | 26 ->
    let n = Int32.to_int @@ get_n r 4 SE.get_int32 in
    if n < 0 then n - two_min_int32 else n
  | 27 ->
    let n = get_n r 8 SE.get_int64 in
    if n > int64_max_int || n < 0L then fail "extract_number: %Lu" n;
    Int64.to_int n
  | n -> fail "bad additional %d" n

let get_float16 s i =
  let half = Char.code s.[i] lsl 8 + Char.code s.[i+1] in
  let mant = half land 0x3ff in
  let value =
    match (half lsr 10) land 0x1f with (* exp *)
    | 31 when mant = 0 -> infinity
    | 31 -> nan
    | 0 -> ldexp (float mant) ~-24
    | exp -> ldexp (float @@ mant + 1024) (exp - 25)
  in
  if half land 0x8000 = 0 then value else ~-. value

exception Break

let extract_list byte1 r f =
  if is_indefinite byte1 then
    let l = ref [] in
    try while true do l := f r :: !l done; assert false with Break -> List.rev !l
  else
    let n = extract_number byte1 r in Array.to_list @@ Array.init n (fun _ -> f r)

let rec extract_pair r =
  let a = extract r in
  let b = try extract r with Break -> fail "extract_pair: unexpected break" in
  a,b
and extract_string byte1 r f =
  if is_indefinite byte1 then
    let b = Buffer.create 10 in
    try while true do Buffer.add_string b (f @@ extract r) done; assert false with Break -> Buffer.contents b
  else
    let n = extract_number byte1 r in get_s r n
and extract r =
  let byte1 = get_byte r in
  match byte1 lsr 5 with
  | 0 -> `Int (extract_number byte1 r)
  | 1 -> `Int (-1 - extract_number byte1 r)
  | 2 -> `Bytes (extract_string byte1 r (function `Bytes s -> s | _ -> fail "extract: not a bytes chunk"))
  | 3 -> `Text (extract_string byte1 r (function `Text s -> s | _ -> fail "extract: not a text chunk"))
  | 4 -> `Array (extract_list byte1 r extract)
  | 5 -> `Map (extract_list byte1 r extract_pair)
  | 6 -> let _tag = extract_number byte1 r in extract r
  | 7 ->
    begin match get_additional byte1 with
    | n when n < 20 -> `Simple n
    | 20 -> `Bool false
    | 21 -> `Bool true
    | 22 -> `Null
    | 23 -> `Undefined
    | 24 -> `Simple (get_byte r)
    | 25 -> `Float (get_n r 2 get_float16)
    | 26 -> `Float (get_n r 4 SE.get_float)
    | 27 -> `Float (get_n r 8 SE.get_double)
    | 31 -> raise Break
    | a -> fail "extract: (7,%d)" a
    end
  | _ -> assert false

let decode s =
  let i = ref 0 in
  let x = try extract (s,i) with Break -> fail "decode: unexpected break" in
  if !i <> String.length s then fail "decode: extra data: len %d pos %d" (String.length s) !i;
  x

let to_diagnostic item =
  let b = Buffer.create 10 in
  let put = Buffer.add_string b in
  let rec write = function
  | `Null -> put "null"
  | `Bool false -> put "false"
  | `Bool true -> put "true"
  | `Simple n -> bprintf b "simple(%d)" n
  | `Undefined -> put "undefined"
  | `Int n -> bprintf b "%d" n
  | `Float f ->
    begin match classify_float f with
    | FP_nan -> put "NaN"
    | FP_infinite -> put (if f < 0. then "-Infinity" else "Infinity")
    | FP_zero | FP_normal | FP_subnormal -> bprintf b "%g" f
    end
  | `Bytes s -> bprintf b "h'%s'" (Encode.to_hex s)
  | `Text s -> bprintf b "\"%s\"" s
  | `Array l ->
    put "[";
    l |> list_iteri (fun i x -> if i <> 0 then put ", "; write x);
    put "]"
  | `Map m ->
    put "{";
    m |> list_iteri (fun i (k,v) -> if i <> 0 then put ", "; write k; put ": "; write v);
    put "}"
  in
  write item;
  Buffer.contents b

end (* Simple *)
