"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import type { NextPage } from "next";
import { decodeEventLog, formatUnits, keccak256, parseUnits, toHex } from "viem";
import { useAccount, useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { ArrowPathIcon, CubeIcon, HomeModernIcon, SparklesIcon } from "@heroicons/react/24/outline";
import { useDeployedContractInfo, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

// USDC has 6 decimals
const USDC_DECIMALS = 6;

// Base USDC address
const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

// USDC ABI for approve and balance
const USDC_ABI = [
  {
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    name: "approve",
    outputs: [{ name: "", type: "bool" }],
    stateMutability: "nonpayable",
    type: "function",
  },
  {
    inputs: [{ name: "account", type: "address" }],
    name: "balanceOf",
    outputs: [{ name: "", type: "uint256" }],
    stateMutability: "view",
    type: "function",
  },
] as const;

const Home: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  // State for gambling
  const [gamblingSecret, setGamblingSecret] = useState("");
  const [pendingSecret, setPendingSecret] = useState<string | null>(null);
  const [lastRollResult, setLastRollResult] = useState<{ won: boolean; payout: string } | null>(null);
  const [revealTxHash, setRevealTxHash] = useState<`0x${string}` | undefined>(undefined);

  // Get contract info
  const { data: housePoolContract } = useDeployedContractInfo({ contractName: "HousePool" });

  // Read pool stats
  const { data: effectivePool, refetch: refetchEffectivePool } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "effectivePool",
  });

  const { data: canRoll, refetch: refetchCanRoll } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "canRoll",
  });

  // Read user USDC balance
  const { data: userUsdcBalance, refetch: refetchUserUsdcBalance } = useReadContract({
    address: USDC_ADDRESS,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: connectedAddress ? [connectedAddress] : undefined,
  });

  // Read commitment
  const { data: commitment, refetch: refetchCommitment } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "getCommitment",
    args: [connectedAddress],
  });

  // Check roll result (only when we have a pending secret)
  const { data: rollCheck, refetch: refetchRollCheck } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "checkRoll",
    args: [connectedAddress, pendingSecret as `0x${string}` | undefined],
  });

  // Write hooks
  const { writeContractAsync: writeHousePool, isPending: isHousePoolWritePending } = useScaffoldWriteContract({
    contractName: "HousePool",
  });

  const { writeContractAsync: writeUsdc, isPending: isUsdcWritePending } = useWriteContract();

  // Watch for reveal transaction receipt
  const { data: revealReceipt } = useWaitForTransactionReceipt({
    hash: revealTxHash,
  });

  // RollRevealed event ABI for decoding
  const rollRevealedAbi = [
    {
      type: "event",
      name: "RollRevealed",
      inputs: [
        { name: "player", type: "address", indexed: true },
        { name: "won", type: "bool", indexed: false },
        { name: "payout", type: "uint256", indexed: false },
      ],
    },
  ] as const;

  // Parse RollRevealed event when receipt arrives
  useEffect(() => {
    if (revealReceipt) {
      if (revealReceipt.logs.length > 0) {
        for (let i = 0; i < revealReceipt.logs.length; i++) {
          const log = revealReceipt.logs[i];
          try {
            const decoded = decodeEventLog({
              abi: rollRevealedAbi,
              data: log.data,
              topics: log.topics,
            });

            if (decoded.eventName === "RollRevealed") {
              const won = decoded.args.won;
              const payout = decoded.args.payout;
              const payoutUsdc = Number(payout) / 1e6;

              setLastRollResult({
                won,
                payout: payoutUsdc.toFixed(2),
              });
              setRevealTxHash(undefined);
              break;
            }
          } catch {
            // Log decode failed, try next
          }
        }
      }
    }
  }, [revealReceipt, revealTxHash]);

  // Parse commitment (needed early for auto-refresh logic)
  const hasCommitment =
    commitment && commitment[0] !== "0x0000000000000000000000000000000000000000000000000000000000000000";

  // Refetch all data
  const refetchAll = useCallback(() => {
    refetchEffectivePool();
    refetchCanRoll();
    refetchUserUsdcBalance();
    refetchCommitment();
    refetchRollCheck();
  }, [refetchEffectivePool, refetchCanRoll, refetchUserUsdcBalance, refetchCommitment, refetchRollCheck]);

  // Auto-refresh (faster when waiting for result)
  useEffect(() => {
    const interval = setInterval(refetchAll, hasCommitment && pendingSecret ? 2000 : 10000);
    return () => clearInterval(interval);
  }, [refetchAll, hasCommitment, pendingSecret]);

  // Generate random secret for gambling
  const generateSecret = () => {
    const randomBytes = crypto.getRandomValues(new Uint8Array(32));
    const secret = toHex(randomBytes);
    setGamblingSecret(secret);
    return secret;
  };

  // Handle commit roll
  const handleCommitRoll = async () => {
    if (!housePoolContract) return;

    try {
      const secret = gamblingSecret || generateSecret();
      const commitHash = keccak256(secret as `0x${string}`);

      setPendingSecret(secret);
      localStorage.setItem("pendingGamblingSecret", secret);

      const rollCost = parseUnits("1", USDC_DECIMALS);
      await writeUsdc({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "approve",
        args: [housePoolContract.address, rollCost],
      });

      await writeHousePool({
        functionName: "commitRoll",
        args: [commitHash],
      });

      setGamblingSecret("");
      refetchAll();
    } catch (error) {
      console.error("Commit roll failed:", error);
    }
  };

  // Handle reveal roll
  const handleRevealRoll = async () => {
    const secret = pendingSecret || localStorage.getItem("pendingGamblingSecret");
    if (!secret) {
      alert("No pending secret found. Please commit first.");
      return;
    }

    if (!secret.startsWith("0x") || secret.length !== 66) {
      alert(`Invalid secret format. Please reset and try again.`);
      return;
    }

    try {
      setLastRollResult(null);

      const hash = await writeHousePool({
        functionName: "revealRoll",
        args: [secret as `0x${string}`],
      });

      setRevealTxHash(hash);

      setPendingSecret(null);
      localStorage.removeItem("pendingGamblingSecret");
      refetchAll();
    } catch (error) {
      console.error("Reveal roll failed:", error);
    }
  };

  // Reset pending commit
  const handleResetCommit = () => {
    setPendingSecret(null);
    localStorage.removeItem("pendingGamblingSecret");
    setGamblingSecret("");
    alert("Commit reset! If you had a pending on-chain commit, wait 256 blocks to call cancelCommit for refund.");
  };

  // Check for pending secret on load
  useEffect(() => {
    const stored = localStorage.getItem("pendingGamblingSecret");
    if (stored) {
      setPendingSecret(stored);
    }
  }, []);

  const isLoading = isHousePoolWritePending || isUsdcWritePending;

  // Format helpers
  const formatUsdc = (value: bigint | undefined) =>
    value ? parseFloat(formatUnits(value, USDC_DECIMALS)).toLocaleString(undefined, { maximumFractionDigits: 2 }) : "0";

  // Parse commitment details
  const commitmentCanReveal = commitment && commitment[2];
  const commitmentIsExpired = commitment && commitment[3];

  // Parse roll check result
  const canCheckRoll = rollCheck && rollCheck[0];
  const isWinner = rollCheck && rollCheck[1];

  return (
    <div className="flex flex-col items-center min-h-screen bg-[radial-gradient(ellipse_at_top,_var(--tw-gradient-stops))] from-base-300 via-base-100 to-base-100">
      {/* Hero Section */}
      <div className="flex flex-col items-center justify-center px-5 py-12 w-full">
        <h1 className="text-5xl font-black mb-2 tracking-tight">
          <span className="bg-gradient-to-r from-amber-400 via-orange-500 to-red-500 bg-clip-text text-transparent">
            🎲 Roll the Dice
          </span>
        </h1>
        <p className="text-base-content/60 mb-6 text-center max-w-md">
          Pay 1 USDC, ~9% chance to win 10 USDC. Fair commit-reveal randomness.
        </p>
      </div>

      {/* Player USDC Balance */}
      {connectedAddress && (
        <div className="bg-gradient-to-br from-green-500/10 to-emerald-500/10 rounded-2xl px-8 py-4 mb-6 border border-green-500/20">
          <div className="flex items-center gap-4">
            <div className="text-3xl">💵</div>
            <div>
              <p className="text-sm text-base-content/60 uppercase tracking-wide">Your USDC</p>
              <p className="text-3xl font-bold text-green-400">${formatUsdc(userUsdcBalance as bigint | undefined)}</p>
            </div>
          </div>
        </div>
      )}

      {/* Game Stats Bar */}
      <div className="flex gap-6 mb-8 text-center">
        <div className="bg-base-100/50 backdrop-blur rounded-xl px-6 py-3 border border-base-300">
          <p className="text-xs text-base-content/50 uppercase">Cost</p>
          <p className="text-xl font-bold">1 USDC</p>
        </div>
        <div className="bg-base-100/50 backdrop-blur rounded-xl px-6 py-3 border border-base-300">
          <p className="text-xs text-base-content/50 uppercase">Win Rate</p>
          <p className="text-xl font-bold text-amber-400">~9%</p>
        </div>
        <div className="bg-base-100/50 backdrop-blur rounded-xl px-6 py-3 border border-base-300">
          <p className="text-xs text-base-content/50 uppercase">Payout</p>
          <p className="text-xl font-bold text-green-400">10 USDC</p>
        </div>
        <div className="bg-base-100/50 backdrop-blur rounded-xl px-6 py-3 border border-base-300">
          <p className="text-xs text-base-content/50 uppercase">Pool</p>
          <p className="text-xl font-bold">${formatUsdc(effectivePool)}</p>
        </div>
      </div>

      {/* Main Gambling Panel */}
      <div className="bg-base-100 rounded-3xl p-8 shadow-2xl border border-base-300 w-full max-w-lg mb-8">
        {/* Roll Result Display */}
        {lastRollResult && (
          <div
            className={`rounded-2xl p-8 text-center mb-6 border-2 ${
              lastRollResult.won
                ? "bg-gradient-to-br from-green-500/20 to-emerald-500/20 border-green-500"
                : "bg-gradient-to-br from-red-500/20 to-orange-500/20 border-red-500"
            }`}
          >
            <div className="text-6xl mb-3">{lastRollResult.won ? "🎉" : "💀"}</div>
            <p className={`text-3xl font-black ${lastRollResult.won ? "text-green-400" : "text-red-400"}`}>
              {lastRollResult.won ? "WINNER!" : "Better luck next time"}
            </p>
            {lastRollResult.won && <p className="text-2xl mt-2 font-bold">+{lastRollResult.payout} USDC</p>}
            <button className="btn btn-ghost btn-sm mt-4 opacity-60" onClick={() => setLastRollResult(null)}>
              Dismiss
            </button>
          </div>
        )}

        {!canRoll ? (
          <div className="bg-error/10 border border-error/30 rounded-xl p-6 text-center">
            <div className="text-4xl mb-2">🚫</div>
            <p className="text-error font-bold text-lg">Rolling Disabled</p>
            <p className="text-sm text-base-content/60 mt-1">Pool needs more liquidity</p>
            <Link href="/house" className="btn btn-outline btn-sm mt-4">
              Add Liquidity →
            </Link>
          </div>
        ) : hasCommitment ? (
          <div className="space-y-4">
            {/* Show result if we can check */}
            {canCheckRoll && pendingSecret ? (
              isWinner ? (
                <div className="rounded-2xl p-8 text-center border-2 bg-gradient-to-br from-green-500/20 to-emerald-500/20 border-green-500">
                  <div className="text-6xl mb-3">🎉</div>
                  <p className="text-3xl font-black text-green-400">YOU WON!</p>
                  <p className="text-xl mt-2">Claim your 10 USDC below</p>
                </div>
              ) : (
                <div className="rounded-2xl p-8 text-center border-2 bg-gradient-to-br from-red-500/20 to-orange-500/20 border-red-500">
                  <div className="text-6xl mb-3">💀</div>
                  <p className="text-3xl font-black text-red-400">You Lost</p>
                  <p className="text-base-content/60 mt-2">No need to reveal - try again!</p>
                </div>
              )
            ) : (
              <div className="bg-gradient-to-r from-primary/10 to-secondary/10 rounded-xl p-5">
                <div className="flex items-center gap-3 mb-3">
                  <div className="bg-primary/20 rounded-full p-2">
                    <CubeIcon className="h-6 w-6 text-primary" />
                  </div>
                  <div>
                    <span className="font-bold text-lg">Roll Pending</span>
                    <p className="text-sm text-base-content/60">Block: {commitment[1].toString()}</p>
                  </div>
                </div>

                {commitmentIsExpired ? (
                  <div className="bg-error/10 rounded-lg p-3 text-error text-sm">
                    ⚠️ Commitment expired (256 blocks passed) - cancel for refund
                  </div>
                ) : commitmentCanReveal ? (
                  pendingSecret ? (
                    <div className="bg-warning/10 rounded-lg p-3 text-warning text-sm">⏳ Checking result...</div>
                  ) : (
                    <div className="bg-error/10 rounded-lg p-3 text-error text-sm">
                      ⚠️ Secret lost! Enter it below or wait for expiry to cancel.
                    </div>
                  )
                ) : (
                  <div className="bg-warning/10 rounded-lg p-3 text-warning text-sm">
                    ⏳ Wait 1 block to see result...
                  </div>
                )}
              </div>
            )}

            {/* Manual secret entry if lost */}
            {!pendingSecret && !commitmentIsExpired && (
              <div className="form-control">
                <label className="label">
                  <span className="label-text text-warning">Enter lost secret to recover:</span>
                </label>
                <input
                  type="text"
                  className="input input-bordered input-sm font-mono text-xs"
                  placeholder="0x..."
                  value={gamblingSecret}
                  onChange={e => {
                    setGamblingSecret(e.target.value);
                    if (e.target.value.startsWith("0x") && e.target.value.length === 66) {
                      setPendingSecret(e.target.value);
                      localStorage.setItem("pendingGamblingSecret", e.target.value);
                    }
                  }}
                />
              </div>
            )}

            {/* Only show claim button for winners */}
            {canCheckRoll && isWinner && pendingSecret && (
              <button
                className="btn btn-success btn-lg w-full gap-2 text-lg"
                onClick={handleRevealRoll}
                disabled={isLoading}
              >
                {isLoading ? (
                  <span className="loading loading-spinner loading-md"></span>
                ) : (
                  <>
                    <ArrowPathIcon className="h-6 w-6" />
                    CLAIM 10 USDC!
                  </>
                )}
              </button>
            )}

            {/* For losers, show button to roll again (new commit) */}
            {canCheckRoll && !isWinner && pendingSecret && (
              <button
                className="btn btn-primary btn-lg w-full gap-2 text-lg"
                onClick={async () => {
                  // Clear old secret and start new commit
                  setPendingSecret(null);
                  localStorage.removeItem("pendingGamblingSecret");
                  await handleCommitRoll();
                }}
                disabled={isLoading}
              >
                {isLoading ? (
                  <span className="loading loading-spinner loading-md"></span>
                ) : (
                  <>
                    <SparklesIcon className="h-6 w-6" />
                    ROLL AGAIN (1 USDC)
                  </>
                )}
              </button>
            )}

            {commitmentIsExpired && (
              <button
                className="btn btn-warning w-full"
                onClick={async () => {
                  try {
                    await writeHousePool({ functionName: "cancelCommit" });
                    refetchAll();
                  } catch (e) {
                    console.error(e);
                  }
                }}
                disabled={isLoading}
              >
                Cancel & Get 1 USDC Refund
              </button>
            )}

            <button className="btn btn-ghost btn-sm w-full text-error/60" onClick={handleResetCommit}>
              Clear Local Data
            </button>
          </div>
        ) : (
          <div className="space-y-5">
            <p className="text-sm text-base-content/60 text-center">
              Two-step process: Click to start, wait a moment, then reveal.
            </p>

            <button
              className="btn btn-primary btn-lg w-full gap-2 text-lg"
              onClick={handleCommitRoll}
              disabled={isLoading || !connectedAddress}
            >
              {isLoading ? (
                <span className="loading loading-spinner loading-md"></span>
              ) : (
                <>
                  <SparklesIcon className="h-6 w-6" />
                  ROLL (1 USDC)
                </>
              )}
            </button>
          </div>
        )}
      </div>

      {/* Link to House */}
      <div className="text-center pb-12">
        <p className="text-base-content/50 mb-3">Want to be the house instead?</p>
        <Link href="/house" className="btn btn-outline gap-2">
          <HomeModernIcon className="h-5 w-5" />
          Manage House Pool
        </Link>
      </div>
    </div>
  );
};

export default Home;
