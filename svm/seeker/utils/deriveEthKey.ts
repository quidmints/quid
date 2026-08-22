import { hkdf } from '@noble/hashes/hkdf.js'
import { sha256 } from '@noble/hashes/sha2.js'
import { p256 } from '@noble/curves/nist.js'

export interface DerivedEthKey {
  compressedPublicKey: Uint8Array
  ethAddress: string
  compressedKeyHash: Uint8Array
}

const DERIVE_MESSAGE = 'QU!D cross-chain key derivation v1'
const HKDF_INFO = new TextEncoder().encode('quid-eth-key-v1')

export async function deriveEthKeyFromWallet(
  signMessage: (msg: Uint8Array) => Promise<Uint8Array>,
  walletAddress: string,
): Promise<DerivedEthKey> {
  const message = new TextEncoder().encode(DERIVE_MESSAGE)
  const signature = await signMessage(message)
  const salt = new TextEncoder().encode(walletAddress)
  // 48 bytes, not 32: `randomSecretKey` reduces the seed into [1, n-1], and
  // feeding it exactly the field size would leave a modular bias. The extra
  // half-field of entropy is what NIST SP 800-133 calls for, and letting the
  // curve do the reduction is safer than reaching for a raw scalar helper.
  const seed = hkdf(sha256, signature, salt, HKDF_INFO, 48)
  const privKey = p256.utils.randomSecretKey(seed)
  const compressedPublicKey = p256.getPublicKey(privKey, true)
  const compressedKeyHash = sha256(compressedPublicKey)
  const uncompressedKey = p256.getPublicKey(privKey, false)
  const pubHash = sha256(uncompressedKey.slice(1))
  const ethAddress = '0x' + Array.from(pubHash.slice(12))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
  return { compressedPublicKey, ethAddress, compressedKeyHash }
}
