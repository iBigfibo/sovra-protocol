// api/faucet.js
// Sovra Protocol — Sepolia ETH Faucet
// Deploy this as a Vercel serverless function
// Environment variables needed in Vercel:
//   FAUCET_PRIVATE_KEY  = private key of your faucet wallet (no 0x prefix)
//   FAUCET_RPC_URL      = https://rpc.sepolia.org (or use Alchemy/Infura for reliability)

const { ethers } = require("ethers");

// ── Config ──
const FAUCET_AMOUNT    = ethers.parseEther("0.02");   // 0.02 ETH per claim
const COOLDOWN_HOURS   = 24;                           // one claim per 24 hours
const MIN_BALANCE      = ethers.parseEther("0.005");  // don't send if user already has enough

// In-memory store for rate limiting (resets on cold start — good enough for testnet)
// For production use Redis or a database
const claims = {};

export default async function handler(req, res) {

  // ── CORS ──
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(200).end(); return; }
  if (req.method !== "POST")    { res.status(405).json({ error: "Method not allowed" }); return; }

  const { address } = req.body;

  // ── Validate address ──
  if (!address || !ethers.isAddress(address)) {
    return res.status(400).json({ error: "Invalid wallet address" });
  }

  const addr = address.toLowerCase();

  // ── Rate limit — 1 claim per 24 hours per wallet ──
  const now      = Date.now();
  const lastClaim= claims[addr] || 0;
  const cooldown = COOLDOWN_HOURS * 3600 * 1000;

  if (now - lastClaim < cooldown) {
    const hoursLeft = Math.ceil((cooldown - (now - lastClaim)) / 3600000);
    return res.status(429).json({
      error: `Already claimed. Try again in ${hoursLeft} hour(s).`,
      hoursLeft,
    });
  }

  // ── IP rate limit — max 3 claims per IP per 24 hours ──
  const ip         = req.headers["x-forwarded-for"]?.split(",")[0] || req.socket?.remoteAddress || "unknown";
  const ipKey      = `ip_${ip}`;
  const ipClaims   = claims[ipKey] || [];
  const recentIp   = ipClaims.filter(t => now - t < cooldown);
  if (recentIp.length >= 3) {
    return res.status(429).json({ error: "Too many requests from this IP. Try again later." });
  }

  // ── Setup provider and faucet wallet ──
  const rpcUrl     = process.env.FAUCET_RPC_URL || "https://rpc.sepolia.org";
  const privateKey = process.env.FAUCET_PRIVATE_KEY;

  if (!privateKey) {
    return res.status(500).json({ error: "Faucet not configured. Contact admin." });
  }

  try {
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const faucetWallet = new ethers.Wallet("0x" + privateKey.replace("0x", ""), provider);

    // ── Check faucet balance ──
    const faucetBal = await provider.getBalance(faucetWallet.address);
    if (faucetBal < FAUCET_AMOUNT) {
      return res.status(503).json({ error: "Faucet is empty. Contact admin to refill." });
    }

    // ── Check if user already has enough ETH ──
    const userBal = await provider.getBalance(address);
    if (userBal >= MIN_BALANCE) {
      return res.status(400).json({
        error: `You already have ${parseFloat(ethers.formatEther(userBal)).toFixed(4)} ETH — enough for gas.`,
      });
    }

    // ── Send ETH ──
    const tx = await faucetWallet.sendTransaction({
      to:    address,
      value: FAUCET_AMOUNT,
    });

    // ── Record claim ──
    claims[addr]  = now;
    claims[ipKey] = [...recentIp, now];

    return res.status(200).json({
      success: true,
      amount:  "0.02",
      txHash:  tx.hash,
      message: "0.02 Sepolia ETH sent to your wallet!",
    });

  } catch (e) {
    console.error("Faucet error:", e);
    return res.status(500).json({ error: "Transaction failed. Try again shortly." });
  }
}
