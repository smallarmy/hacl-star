module Spec.Poly1305.Lemmas

val lemma_prime_value: n:nat -> Lemma
  (requires (n = 130))
  (ensures (pow2 n - 5 = 0x3fffffffffffffffffffffffffffffffb))
  [SMTPat (pow2 n - 5)]
let lemma_prime_value n = assert_norm(pow2 130 - 5 = 0x3fffffffffffffffffffffffffffffffb)

