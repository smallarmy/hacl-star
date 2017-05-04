module Spec.AES

open FStar.Mul
open FStar.Seq
open FStar.BitVector
open FStar.UInt
open FStar.Endianness
open Spec.GaloisField
open Spec.Sbox


let irr : polynomial 7 = to_vec #8 0xd8
let gf8 = mk_field 8 irr
let elem = felem gf8
let zero = zero #gf8
let op_Plus_At = fadd #gf8
let op_Star_At = fmul #gf8

type vec = v:seq elem{length v = 4}
type block = b:seq elem{length b = 16}
type epdkey = k:seq elem{length k = 240}

type word = w:bytes{length w <= 16}
type word_16 = w:bytes{length w = 16}
type key = k:bytes{length k = 32}


#set-options "--z3rlimit 100 --initial_fuel 0 --max_fuel 0 --initial_ifuel 0 --max_ifuel 0"

val reverse: #a:Type -> s:seq a -> Tot (r:seq a{length s = length r /\
  (forall (i:nat{i < length s}). index s i == index r (length r - i - 1))})
  (decreases (length s))
let rec reverse #a s =
  if length s = 0 then createEmpty
  else begin
    let ans = snoc (reverse (tail s)) (head s) in
    assert(forall (i:nat{i < length s - 1}). index s (i + 1) == index ans (length s - 1 - i - 1));
    assert(forall (i:nat{i > 0 /\ i < length s}). index s i == index s ((i - 1) + 1));
    ans
  end

let rev_elem (e:elem) : elem = reverse e
let to_elem (u:UInt8.t) : elem = reverse (to_vec (UInt8.v u))
let from_elem (e:elem) : UInt8.t = UInt8.uint_to_t (from_vec (reverse e))

let pad (w:word) : Tot word_16 = w @| (create (16 - length w) 0uy)
let encode (w:word) : Tot block = Spec.Loops.seq_map to_elem (pad w)
let decode (e:block) : Tot word_16 = Spec.Loops.seq_map from_elem e


let rotate (s:vec) (i:nat{i < 4}) = slice s i 4 @| slice s 0 i

let shift (a:block) (r:nat{r < 4}) (i:nat{i < 4}) : block =
  let res = a in
  let res = upd res (r +  0) (index a ((r +  0 + i * 4) % 16)) in
  let res = upd res (r +  4) (index a ((r +  4 + i * 4) % 16)) in
  let res = upd res (r +  8) (index a ((r +  8 + i * 4) % 16)) in
  let res = upd res (r + 12) (index a ((r + 12 + i * 4) % 16)) in
  res

let dot (s1:vec) (s2:vec) : elem =
  (index s1 0 *@ index s2 0) +@
  (index s1 1 *@ index s2 1) +@
  (index s1 2 *@ index s2 2) +@
  (index s1 3 *@ index s2 3)
  
let matdot (m:block) (s:vec) : vec =
  let res = create 4 zero in
  let res = upd res 0 (dot (slice m  0  4) s) in
  let res = upd res 1 (dot (slice m  4  8) s) in
  let res = upd res 2 (dot (slice m  8 12) s) in
  let res = upd res 3 (dot (slice m 12 16) s) in
  res

let mixmat : block = Spec.Loops.seq_map to_elem
  (createL [2uy; 3uy; 1uy; 1uy;
            1uy; 2uy; 3uy; 1uy;
	    1uy; 1uy; 2uy; 3uy;
	    3uy; 1uy; 1uy; 2uy])
let invmixmat : block = Spec.Loops.seq_map to_elem
  (createL [14uy; 11uy; 13uy;  9uy;
             9uy; 14uy; 11uy; 13uy;
	    13uy;  9uy; 14uy; 11uy;
	    11uy; 13uy;  9uy; 14uy])

let getSbox (e:elem) : elem = rev_elem (sbox (rev_elem e))
let getinvSbox (e:elem) : elem = rev_elem (inv_sbox (rev_elem e))


let rec rcon (i:pos) : elem =
  if i = 1 then to_elem 1uy
  else (to_elem 2uy) *@ rcon (i - 1)

let keyScheduleCore (s:vec) (i:pos) : vec =
  let res = rotate s 1 in
  let res = Spec.Loops.seq_map getSbox res in
  let res = upd res 0 (index res 0 +@ rcon i) in
  res

val keyExpansion_aux: k:seq elem{length k >= 32 /\ length k <= 240 /\ length k % 4 = 0} ->
  Tot (r:seq elem{length k + length r = 240}) (decreases (240 - length k))
let rec keyExpansion_aux k =
  let t = slice k (length k - 4) (length k) in
  if length k > 236 then (assert(length k = 240); createEmpty)
  else if length k % 32 = 0 then
    let t = keyScheduleCore t (length k / 32) in
    let t = Spec.Loops.seq_map2 op_Plus_At t (slice k (length k - 32) (length k - 28)) in
    t @| keyExpansion_aux (k @| t)
  else if length k % 32 = 16 then
    let t = Spec.Loops.seq_map getSbox t in
    let t = Spec.Loops.seq_map2 op_Plus_At t (slice k (length k - 32) (length k - 28)) in
    t @| keyExpansion_aux (k @| t)
  else
    let t = Spec.Loops.seq_map2 op_Plus_At t (slice k (length k - 32) (length k - 28)) in
    t @| keyExpansion_aux (k @| t)
 
let keyExpansion (k:key) : epdkey =
  let ek = Spec.Loops.seq_map to_elem k in
  ek @| keyExpansion_aux ek


let addRoundKey (a:block) (k:block) : block = Spec.Loops.seq_map2 op_Plus_At a k

let shiftRows (a:block) : block =
  let a = shift a 0 0 in
  let a = shift a 1 1 in
  let a = shift a 2 2 in
  let a = shift a 3 3 in
  a
let invShiftRows (a:block) : block =
  let a = shift a 0 0 in
  let a = shift a 1 3 in
  let a = shift a 2 2 in
  let a = shift a 3 1 in
  a

let subBytes (a:block) : block = Spec.Loops.seq_map getSbox a
let invSubBytes (a:block) : block = Spec.Loops.seq_map getinvSbox a

let mixColumns (a:block) : block =
  matdot mixmat (slice a  0  4) @|
  matdot mixmat (slice a  4  8) @|
  matdot mixmat (slice a  8 12) @|
  matdot mixmat (slice a 12 16)
let invMixColumns (a:block) : block =
  matdot invmixmat (slice a  0  4) @|
  matdot invmixmat (slice a  4  8) @|
  matdot invmixmat (slice a  8 12) @|
  matdot invmixmat (slice a 12 16)

let rec cipher_loop (a:block) (k:epdkey) (i:nat{i <= 14}) : Tot block (decreases (14 - i)) =
  if i = 14 then a else
  let a = subBytes a in
  let a = shiftRows a in
  let a = mixColumns a in
  let a = addRoundKey a (slice k (i * 16) (i * 16 + 16)) in
  cipher_loop a k (i + 1)

let cipher (w:word) (k:key) : word_16 =
  let a = encode w in
  let k = keyExpansion k in
  let a = addRoundKey a (slice k 0 16) in
  let a = cipher_loop a k 1 in
  let a = subBytes a in
  let a = shiftRows a in
  let a = addRoundKey a (slice k 224 240) in
  decode a

let rec inv_cipher_loop (a:block) (k:epdkey) (i:nat{i < 14}) : Tot block (decreases i) =
  if i = 0 then a else
  let a = addRoundKey a (slice k (i * 16) (i * 16 + 16)) in
  let a = invMixColumns a in
  let a = invShiftRows a in
  let a = invSubBytes a in
  inv_cipher_loop a k (i - 1)

let inv_cipher (w:word) (k:key) : word_16 =
  let a = encode w in
  let k = keyExpansion k in
  let a = addRoundKey a (slice k 224 240) in
  let a = invShiftRows a in
  let a = invSubBytes a in
  let a = inv_cipher_loop a k 13 in
  let a = addRoundKey a (slice k 0 16) in
  decode a


let msg : word = createL [
  0x00uy; 0x11uy; 0x22uy; 0x33uy; 0x44uy; 0x55uy; 0x66uy; 0x77uy;
  0x88uy; 0x99uy; 0xaauy; 0xbbuy; 0xccuy; 0xdduy; 0xeeuy; 0xffuy ]

let k : key = createL [
  0x00uy; 0x01uy; 0x02uy; 0x03uy; 0x04uy; 0x05uy; 0x06uy; 0x07uy;
  0x08uy; 0x09uy; 0x0auy; 0x0buy; 0x0cuy; 0x0duy; 0x0euy; 0x0fuy;
  0x10uy; 0x11uy; 0x12uy; 0x13uy; 0x14uy; 0x15uy; 0x16uy; 0x17uy;
  0x18uy; 0x19uy; 0x1auy; 0x1buy; 0x1cuy; 0x1duy; 0x1euy; 0x1fuy ]

let expected : word = createL [
  0x8euy; 0xa2uy; 0xb7uy; 0xcauy; 0x51uy; 0x67uy; 0x45uy; 0xbfuy;
  0xeauy; 0xfcuy; 0x49uy; 0x90uy; 0x4buy; 0x49uy; 0x60uy; 0x89uy
]
  
let test() = Spec.Sbox.test() && cipher msg k = expected && inv_cipher expected k = msg

