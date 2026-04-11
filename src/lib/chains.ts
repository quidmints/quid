
export type Runtime = 'evm' | 'svm'

export interface Chain {
  id: number
  name: string
  icon: string
  hex: string           // EVM chain hex (empty for Solana)
  explorer: string
  color: string
  enabled: boolean
  hasLeverage: boolean   // Unichain doesn't have Amp
  runtime: Runtime
  rpcUrl?: string        // Solana RPC endpoint (EVM uses wallet's)
}

export interface Contracts {
  vogue: string
  vogueCore: string
  rover: string
  aux: string
  basket: string
  weth: string
  hook: string
  uma: string
  amp: string
  court: string
  jury: string
}

// Solana program addresses — separate from EVM Contracts
export interface SolanaPrograms {
  safta: string          // SAFTA prediction market program
  quid: string           // QU!D stablecoin program ID
  quidMint: string       // QU!D SPL token mint address (distinct from program ID)
}

export interface StableToken {
  symbol: string
  address: string
  decimals: number
  isVault?: boolean
}

// ─── Well-Known Solana Programs ──────────────────────────────────

export const SYSTEM_PROGRAM = '11111111111111111111111111111111'
export const TOKEN_PROGRAM = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA'
export const ASSOCIATED_TOKEN_PROGRAM = 'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL'

// ─── EVM Chains ──────────────────────────────────────────────────

export const CHAINS: Record<number, Chain> = {
  1:     { id: 1,     name: 'Ethereum', icon: '⟠', hex: '0x1',    explorer: 'https://etherscan.io',     color: '#627EEA', enabled: true,  hasLeverage: true,  runtime: 'evm' },
  137:   { id: 137,   name: 'Polygon',  icon: '🟣', hex: '0x89',   explorer: 'https://polygonscan.com',  color: '#8247E5', enabled: true,  hasLeverage: true,  runtime: 'evm' },
  8453:  { id: 8453,  name: 'Base',     icon: '🔵', hex: '0x2105', explorer: 'https://basescan.org',     color: '#0052FF', enabled: true,  hasLeverage: true,  runtime: 'evm' },
  42161: { id: 42161, name: 'Arbitrum', icon: '🔷', hex: '0xa4b1', explorer: 'https://arbiscan.io',      color: '#28A0F0', enabled: true,  hasLeverage: true,  runtime: 'evm' },
  130:   { id: 130,   name: 'Unichain', icon: '🦄', hex: '0x82',   explorer: 'https://uniscan.xyz',      color: '#FF007A', enabled: false, hasLeverage: false, runtime: 'evm' },
}

// ─── Solana Networks ─────────────────────────────────────────────
// Negative IDs avoid collision with EVM chain IDs.
//
// Phantom detects localnet when configured in developer mode:
//   Settings → Developer Settings → Enable "Testnet Mode"
//   Change Network → select "Localnet" (points to http://127.0.0.1:8899)
//
// Switch to mainnet later:
//   1. In Phantom: disable "Testnet Mode" or set network to "Mainnet Beta"
//   2. Here: set SOLANA_NETWORKS[-3].enabled = true, [-1].enabled = false
//   3. Update SOLANA_PROGRAMS[-3] with audited program IDs

export const SOLANA_NETWORKS: Record<number, Chain> = {
  [-1]: {
    id: -1,
    name: 'Solana Localnet',
    icon: '◎',
    hex: '',
    explorer: '',
    color: '#9945FF',
    enabled: true,           // ← active for dev
    hasLeverage: false,
    runtime: 'svm',
    rpcUrl: 'http://127.0.0.1:8899',
  },
  [-2]: {
    id: -2,
    name: 'Solana Devnet',
    icon: '◎',
    hex: '',
    explorer: 'https://explorer.solana.com?cluster=devnet',
    color: '#9945FF',
    enabled: false,
    hasLeverage: false,
    runtime: 'svm',
    rpcUrl: 'https://api.devnet.solana.com',
  },
  [-3]: {
    id: -3,
    name: 'Solana',
    icon: '◎',
    hex: '',
    explorer: 'https://explorer.solana.com',
    color: '#9945FF',
    enabled: false,          // ← flip for prod
    hasLeverage: false,
    runtime: 'svm',
    rpcUrl: 'https://api.mainnet-beta.solana.com',
  },
}

// Merged view — all chains, both runtimes
export const ALL_CHAINS: Record<number, Chain> = { ...CHAINS, ...SOLANA_NETWORKS }

export const ENABLED_CHAINS = Object.values(ALL_CHAINS).filter(c => c.enabled)
export const ENABLED_EVM_CHAINS = ENABLED_CHAINS.filter(c => c.runtime === 'evm')
export const ENABLED_SOL_CHAINS = ENABLED_CHAINS.filter(c => c.runtime === 'svm')

// ─── Phantom Wallet Helpers ──────────────────────────────────────

/**
 * Detect Phantom wallet. Returns the Solana provider or null.
 */
export const getPhantomProvider = (): any | null => {
  if (typeof window === 'undefined') return null
  const w = window as any
  if (w.phantom?.solana?.isPhantom) return w.phantom.solana
  if (w.solana?.isPhantom) return w.solana
  return null
}

export const isPhantomInstalled = (): boolean => getPhantomProvider() !== null

/**
 * Get the active Solana network ID based on what's enabled in config.
 * Returns -1 (localnet), -2 (devnet), or -3 (mainnet).
 */
export const getActiveSolanaNetwork = (): number => {
  const enabled = ENABLED_SOL_CHAINS[0]
  return enabled?.id ?? -1
}

/**
 * Get Solana RPC URL for the active network.
 */
export const getSolanaRpcUrl = (): string => {
  const net = SOLANA_NETWORKS[getActiveSolanaNetwork()]
  return net?.rpcUrl ?? 'http://127.0.0.1:8899'
}

// ─── EVM Contracts ───────────────────────────────────────────────

export const CONTRACTS: Record<number, Contracts> = {
  1: {
    vogue:     '0x29BD9450FF36cC95ad7d5F894c1f3A56a9aE089B',
    vogueCore: '0xFBadCAc0dAe4b502F3fdEee278cFBAa96d91F31BF',
    rover:     '0x5FA4aE23F98353d3CCaAc47a6873bF254CD74CD7',
    aux:       '0x838bDE0CaC881e51c1D1339db2572B3AF2C3df2F',
    basket:    '0xA3Da018f10ac6A38183d3FFDf928C3375fB7A3c6',
    weth:      '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    hook:      '0x946673497452180b664A25de69367Db991b25529',
    uma:       '0xA755A90D2A98C80e518b5411fc7e65d00fBb4E33',
    amp:       '0xEA905AC260037Ba53305AB06a683E89C651EDCfC',
    court:     '0x542D537FA9544D4d692559a47061188510b8289f',
    jury:      '0x1e82eCA9DECd2fA0e4582af911E00552b4626aCc',
  },
  137: {
    vogue:     '0xbA45bF3B4701aE737Dd69034F50F3d821240A346',
    vogueCore: '0xc2870935241dAB0A61AeD3892050aa4D9742E9eD',
    rover:     '0x2073cC944656e91bf535dB2AA26D3EE5B05124Ff',
    aux:       '0x73ed5341ea060d4CfdeC7bcc38e6c83BDa1F24A2',
    basket:    '0xa55a6e4d367AbdA1C6C74543B55E075575bf3a98',
    weth:      '0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619',
    hook:      '0x80B02fae6DCe12030Fd9b741F1731F4B412BeDFb',
    uma:       '0x99d9050AdBB262184aE867a0C9A76ecA4e2043C7',
    amp:       '0x9D6b0D7100e547ad3eC284AA4918f0679ef504e6',
    court:     '0x48106245E3Da0a6c1C4515964ACF90AA70d4ccc6',
    jury:      '0x5743c295867a32452B48C2bd18EeBf922Aba91d7',
  },
  8453: {
    vogue:     '0x48106245E3Da0a6c1C4515964ACF90AA70d4ccc6',
    vogueCore: '0x0A7419B1825C1C94c1d753B4eFE2580b606D90e0',
    rover:     '0x5743c295867a32452B48C2bd18EeBf922Aba91d7',
    aux:       '0x8f290a2Dbee861a9981e5D49CF34d099eA668De5',
    basket:    '0x6fAdbd93f72C72e9D6364B133dbAa9748730265C',
    weth:      '0x4200000000000000000000000000000000000006',
    hook:      '0xF188Bdf855d9F1FEFFE51e71E3b30A7a8F4a212E',
    uma:       '0xa55a6e4d367AbdA1C6C74543B55E075575bf3a98',
    amp:       '0x80B02fae6DCe12030Fd9b741F1731F4B412BeDFb',
    court:     '0xe01dE0398d6d115c3bEEc957b0121194aFD814bd',
    jury:      '0xDcAcB4114Ce4D2839c1fF0C06920E0B2c265D630',
  },
  42161: {
    vogue:     '0x2073cC944656e91bf535dB2AA26D3EE5B05124Ff',
    vogueCore: '0xbA45bF3B4701aE737Dd69034F50F3d821240A346',
    rover:     '0x9D6b0D7100e547ad3eC284AA4918f0679ef504e6',
    aux:       '0xc2870935241dAB0A61AeD3892050aa4D9742E9eD',
    basket:    '0x2c909bFDF64e04f1a62B57501f3d7E8F81849555',
    weth:      '0x82aF49447D8a07e3bd95BD0d56f35241523fBab1',
    hook:      '0xa55a6e4d367AbdA1C6C74543B55E075575bf3a98',
    uma:       '0xc48455f90Cf7134a7cB1f4D419F247F9fF532D93',
    amp:       '0x99d9050AdBB262184aE867a0C9A76ecA4e2043C7',
    court:     '0x5743c295867a32452B48C2bd18EeBf922Aba91d7',
    jury:      '0x80B02fae6DCe12030Fd9b741F1731F4B412BeDFb',
  },
  130: { // TODO update
    vogue: '0xA42EC270cCC8176e966A454DE91ca20eEB845AB0',
    vogueCore: '0x1d8227d7cDABce4aC80182857Bc0dE28645Fae53',
    rover: '0x19F4B1215456f706475e0Ee408D216EBB181129A',
    aux: '0x146D7bEC5ACCC0446B2052AFc44b21C05B1F93b1',
    basket: '0xBae245f523f4Fb2c377895Ee6d30De5488d15a83',
    weth: '0x4200000000000000000000000000000000000006',
    hook: '0x0000000000000000000000000000000000000000',
    uma: '0x0000000000000000000000000000000000000000',
    amp: '0x0000000000000000000000000000000000000000',
    court: '0x0000000000000000000000000000000000000000',
    jury: '0x0000000000000000000000000000000000000000',
  },
}

export const AMP_ADDRESSES: Record<number, string> = {
  1:     '0xEA905AC260037Ba53305AB06a683E89C651EDCfC',
  137:   '0x9D6b0D7100e547ad3eC284AA4918f0679ef504e6',
  8453:  '0x80B02fae6DCe12030Fd9b741F1731F4B412BeDFb',
  42161: '0x99d9050AdBB262184aE867a0C9A76ecA4e2043C7',
}

export const STABLES: Record<number, StableToken[]> = {
  1: [
    { symbol: 'USDC', address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48', decimals: 6 },
    { symbol: 'USDT', address: '0xdAC17F958D2ee523a2206206994597C13D831ec7', decimals: 6 },
    { symbol: 'DAI', address: '0x6B175474E89094C44Da98b954EedeAC495271d0F', decimals: 18 },
    { symbol: 'PYUSD', address: '0x6c3ea9036406852006290770BEdFcAbA0e23A0e8', decimals: 6 },
    { symbol: 'USDS', address: '0xdC035D45d973E3EC169d2276DDab16f1e407384F', decimals: 18 },
    { symbol: 'USDe', address: '0x4c9EDD5852cd905f086C759E8383e09bff1E68B3', decimals: 18 },
    { symbol: 'crvUSD', address: '0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E', decimals: 18 },
    { symbol: 'FRAX', address: '0xCAcd6fd266aF91b8AeD52aCCc382b4e165586E29', decimals: 18 },
    { symbol: 'GHO', address: '0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f', decimals: 18 },
    { symbol: 'BOLD', address: '0x6440f144b7e50d6a8439336510312d2f54beb01d', decimals: 18 },
    { symbol: 'sDAI', address: '0x83F20F44975D03b1b09e64809B757c47f942BEeA', decimals: 18, isVault: true },
    { symbol: 'sFRAX', address: '0xcf62F905562626CfcDD2261162a51fd02Fc9c5b6', decimals: 18, isVault: true },
    { symbol: 'sUSDS', address: '0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD', decimals: 18, isVault: true },
    { symbol: 'sUSDe', address: '0x9D39A5DE30e57443BfF2A8307A4256c8797A3497', decimals: 18, isVault: true },
    { symbol: 'scrvUSD', address: '0x0655977FEb2f289A4aB78af67BAB0d17aAb84367', decimals: 18, isVault: true },
  ],
  137: [
    { symbol: 'USDC', address: '0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359', decimals: 6 },
    { symbol: 'USDT', address: '0xc2132D05D31c914a87C6611C10748AEb04B58e8F', decimals: 6 },
    { symbol: 'DAI', address: '0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063', decimals: 18 },
    { symbol: 'FRAX', address: '0x45c32fA6DF82ead1e2EF74d17b76547EDdFaFF89', decimals: 18 },
  ],
  8453: [
    { symbol: 'USDC', address: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', decimals: 6 },
    { symbol: 'USDT', address: '0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2', decimals: 6 },
    { symbol: 'DAI', address: '0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb', decimals: 18 },
    { symbol: 'GHO', address: '0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee', decimals: 18 },
    { symbol: 'USDS', address: '0x820C137fa70C8691f0e44Dc420a5e53c168921Dc', decimals: 18 },
    { symbol: 'USDe', address: '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34', decimals: 18 },
    { symbol: 'crvUSD', address: '0x417Ac0e078398C154EdFadD9Ef675d30Be60Af93', decimals: 18 },
    { symbol: 'FRAX', address: '0xe5020A6d073a794B6E7f05678707dE47986Fb0b6', decimals: 18 },
    { symbol: 'sFRAX', address: '0x91A3f8a8d7a881fBDfcfEcd7A2Dc92a46DCfa14e', decimals: 18, isVault: true },
    { symbol: 'sUSDS', address: '0x5875eEE11Cf8398102FdAd704C9E96607675467a', decimals: 18, isVault: true },
    { symbol: 'sUSDe', address: '0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2', decimals: 18, isVault: true },
    { symbol: 'scrvUSD', address: '0x646A737B9B6024e49f5908762B3fF73e65B5160c', decimals: 18, isVault: true },
  ],
  42161: [
    { symbol: 'USDC', address: '0xaf88d065e77c8cC2239327C5EDb3A432268e5831', decimals: 6 },
    { symbol: 'USDT', address: '0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9', decimals: 6 },
    { symbol: 'DAI', address: '0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1', decimals: 18 },
    { symbol: 'GHO', address: '0x7dfF72693f6A4149b17e7C6314655f6A9F7c8B33', decimals: 18 },
    { symbol: 'USDS', address: '0x6491c05A82219b8D1479057361ff1654749b876b', decimals: 18 },
    { symbol: 'USDe', address: '0x5d3a1Ff2b6BAb83b63cd9AD0787074081a52ef34', decimals: 18 },
    { symbol: 'crvUSD', address: '0x498Bf2B1e120FeD3ad3D42EA2165E9b73f99C1e5', decimals: 18 },
    { symbol: 'FRAX', address: '0x80Eede496655FB9047dd39d9f418d5483ED600df', decimals: 18 },
    { symbol: 'sFRAX', address: '0x5Bff88cA1442c2496f7E475E9e7786383Bc070c0', decimals: 18, isVault: true },
    { symbol: 'sUSDS', address: '0xdDb46999F8891663a8F2828d25298f70416d7610', decimals: 18, isVault: true },
    { symbol: 'sUSDe', address: '0x211Cc4DD073734dA055fbF44a2b4667d5E5fE5d2', decimals: 18, isVault: true },
    { symbol: 'scrvUSD', address: '0xEfB6601Df148677A338720156E2eFd3c5Ba8809d', decimals: 18, isVault: true },
  ],
  130: [
    { symbol: 'USDC', address: '0x078D782b760474a361dDA0AF3839290b0EF57AD6', decimals: 6 },
    { symbol: 'USDT', address: '0x9151434b16b9763660705744891fA906F660EcC5', decimals: 6 },
    { symbol: 'USDS', address: '0x7E10036Acc4B56d4dFCa3b77810356CE52313F9C', decimals: 18 },
    { symbol: 'FRAX', address: '0x80Eede496655FB9047dd39d9f418d5483ED600df', decimals: 18 },
    { symbol: 'sUSDS', address: '0xA06b10Db9F390990364A3984C04FaDf1c13691b5', decimals: 18, isVault: true },
  ],
}
