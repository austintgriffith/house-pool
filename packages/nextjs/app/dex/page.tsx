"use client";

import { useState } from "react";
import type { NextPage } from "next";
import { formatEther, formatUnits, parseEther, parseUnits } from "viem";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { ArrowsRightLeftIcon, BanknotesIcon, MinusCircleIcon, PlusCircleIcon } from "@heroicons/react/24/outline";
import { useDeployedContractInfo, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

// USDC has 6 decimals
const USDC_DECIMALS = 6;

// Initial liquidity amounts for 100:1 ratio
const INITIAL_CREDITS = parseEther("100"); // 100 Credits
const INITIAL_USDC = parseUnits("1", USDC_DECIMALS); // 1 USDC

// USDC ABI for approve
const USDC_ABI = [
  {
    constant: false,
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    name: "approve",
    outputs: [{ name: "", type: "bool" }],
    type: "function",
  },
  {
    constant: true,
    inputs: [{ name: "account", type: "address" }],
    name: "balanceOf",
    outputs: [{ name: "", type: "uint256" }],
    type: "function",
  },
  {
    constant: true,
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    name: "allowance",
    outputs: [{ name: "", type: "uint256" }],
    type: "function",
  },
] as const;

const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

const DexPage: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  // Swap state
  const [swapDirection, setSwapDirection] = useState<"usdcToCredits" | "creditsToUsdc">("usdcToCredits");
  const [swapAmount, setSwapAmount] = useState("");

  // Liquidity state
  const [depositAmount, setDepositAmount] = useState("");
  const [withdrawAmount, setWithdrawAmount] = useState("");

  // Get contract info
  const { data: dexContract } = useDeployedContractInfo({ contractName: "CreditsDex" });
  const { data: creditsContract } = useDeployedContractInfo({ contractName: "Credits" });

  // Read DEX reserves
  const { data: creditReserves, refetch: refetchCreditReserves } = useScaffoldReadContract({
    contractName: "CreditsDex",
    functionName: "getCreditReserves",
  });

  const { data: assetReserves, refetch: refetchAssetReserves } = useScaffoldReadContract({
    contractName: "CreditsDex",
    functionName: "getAssetReserves",
  });

  const { data: totalLiquidity, refetch: refetchTotalLiquidity } = useScaffoldReadContract({
    contractName: "CreditsDex",
    functionName: "totalLiquidity",
  });

  // Read user's liquidity
  const { data: userLiquidity, refetch: refetchUserLiquidity } = useScaffoldReadContract({
    contractName: "CreditsDex",
    functionName: "getLiquidity",
    args: [connectedAddress],
  });

  // Read user's token balances
  const { data: userCreditsBalance, refetch: refetchCreditsBalance } = useScaffoldReadContract({
    contractName: "Credits",
    functionName: "balanceOf",
    args: [connectedAddress],
  });

  const { data: userUsdcBalance, refetch: refetchUsdcBalance } = useReadContract({
    address: USDC_ADDRESS,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: connectedAddress ? [connectedAddress] : undefined,
  });

  // Calculate swap output
  const swapAmountParsed = swapAmount
    ? swapDirection === "usdcToCredits"
      ? parseUnits(swapAmount, USDC_DECIMALS)
      : parseEther(swapAmount)
    : BigInt(0);

  const { data: swapOutput } = useScaffoldReadContract({
    contractName: "CreditsDex",
    functionName: swapDirection === "usdcToCredits" ? "assetInPrice" : "creditInPrice",
    args: [swapAmountParsed],
  });

  // Calculate required USDC for deposit
  const requiredUsdcForDeposit =
    depositAmount && creditReserves && assetReserves && creditReserves > BigInt(0)
      ? (parseEther(depositAmount) * assetReserves) / creditReserves
      : undefined;

  // Get price of 1 Credit in USDC
  const { data: oneCreditPrice } = useScaffoldReadContract({
    contractName: "CreditsDex",
    functionName: "creditInPrice",
    args: [parseEther("1")],
  });

  // Calculate price per credit (USDC value)
  const creditPriceUsd =
    oneCreditPrice !== undefined
      ? parseFloat(formatUnits(oneCreditPrice, USDC_DECIMALS))
      : creditReserves && assetReserves && creditReserves > BigInt(0)
        ? parseFloat(formatUnits(assetReserves, USDC_DECIMALS)) / parseFloat(formatEther(creditReserves))
        : null;

  // Write hooks
  const { writeContractAsync: writeCredits, isPending: isCreditsWritePending } = useScaffoldWriteContract({
    contractName: "Credits",
  });

  const { writeContractAsync: writeDex, isPending: isDexWritePending } = useScaffoldWriteContract({
    contractName: "CreditsDex",
  });

  const { writeContractAsync: writeUsdc, isPending: isUsdcWritePending } = useWriteContract();

  // Refetch all data
  const refetchAll = () => {
    refetchCreditReserves();
    refetchAssetReserves();
    refetchTotalLiquidity();
    refetchUserLiquidity();
    refetchCreditsBalance();
    refetchUsdcBalance();
  };

  // Setup initial liquidity (100 Credits + 1 USDC)
  const handleSetupLiquidity = async () => {
    if (!dexContract || !creditsContract) return;

    try {
      // 1. Approve Credits
      await writeCredits({
        functionName: "approve",
        args: [dexContract.address, INITIAL_CREDITS],
      });

      // 2. Approve USDC
      await writeUsdc({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "approve",
        args: [dexContract.address, INITIAL_USDC],
      });

      // 3. Init DEX with liquidity (credits, reserves, excess=0)
      await writeDex({
        functionName: "init",
        args: [INITIAL_CREDITS, INITIAL_USDC, 0n],
      });

      refetchAll();
    } catch (error) {
      console.error("Setup liquidity failed:", error);
    }
  };

  // Handle adding more liquidity
  const handleDeposit = async () => {
    if (!depositAmount || !dexContract || !requiredUsdcForDeposit) return;

    try {
      const creditsToDeposit = parseEther(depositAmount);

      // 1. Approve Credits
      await writeCredits({
        functionName: "approve",
        args: [dexContract.address, creditsToDeposit],
      });

      // 2. Approve USDC (add a small buffer for rounding)
      const usdcToApprove = requiredUsdcForDeposit + BigInt(1);
      await writeUsdc({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "approve",
        args: [dexContract.address, usdcToApprove],
      });

      // 3. Deposit with slippage protection (pass 0n for no limit)
      await writeDex({
        functionName: "deposit",
        args: [creditsToDeposit, 0n],
      });

      setDepositAmount("");
      refetchAll();
    } catch (error) {
      console.error("Deposit failed:", error);
    }
  };

  // Handle withdrawing liquidity
  const handleWithdraw = async () => {
    if (!withdrawAmount || !dexContract) return;

    try {
      const lpTokensToWithdraw = parseEther(withdrawAmount);

      await writeDex({
        functionName: "withdraw",
        args: [lpTokensToWithdraw],
      });

      setWithdrawAmount("");
      refetchAll();
    } catch (error) {
      console.error("Withdraw failed:", error);
    }
  };

  // Handle swap
  const handleSwap = async () => {
    if (!swapAmount || !dexContract) return;

    try {
      if (swapDirection === "usdcToCredits") {
        const amountIn = parseUnits(swapAmount, USDC_DECIMALS);
        // Approve USDC
        await writeUsdc({
          address: USDC_ADDRESS,
          abi: USDC_ABI,
          functionName: "approve",
          args: [dexContract.address, amountIn],
        });
        // Swap
        await writeDex({
          functionName: "assetToCredit",
          args: [amountIn, BigInt(0)], // 0 minTokensBack for simplicity
        });
      } else {
        const amountIn = parseEther(swapAmount);
        // Approve Credits
        await writeCredits({
          functionName: "approve",
          args: [dexContract.address, amountIn],
        });
        // Swap
        await writeDex({
          functionName: "creditToAsset",
          args: [amountIn, BigInt(0)], // 0 minTokensBack for simplicity
        });
      }

      setSwapAmount("");
      refetchAll();
    } catch (error) {
      console.error("Swap failed:", error);
    }
  };

  const isLoading = isCreditsWritePending || isDexWritePending || isUsdcWritePending;
  const isInitialized = totalLiquidity && totalLiquidity > BigInt(0);

  // Format display values
  const formatCredits = (value: bigint | undefined) =>
    value ? parseFloat(formatEther(value)).toLocaleString(undefined, { maximumFractionDigits: 4 }) : "0";

  const formatUsdc = (value: bigint | undefined) =>
    value ? parseFloat(formatUnits(value, USDC_DECIMALS)).toLocaleString(undefined, { maximumFractionDigits: 4 }) : "0";

  return (
    <div className="flex flex-col items-center pt-8 px-4 pb-12">
      <h1 className="text-3xl font-bold mb-2">Credits DEX</h1>
      <p className="text-base-content/60 mb-2">Swap Credits ↔ USDC</p>

      {/* Credit Price Display */}
      {isInitialized && creditPriceUsd !== null && (
        <div className="bg-base-100 border border-primary/30 rounded-2xl px-6 py-3 mb-8 shadow-sm">
          <p className="text-sm text-base-content/60 text-center">1 Credit =</p>
          <p className="text-3xl font-bold text-primary text-center">
            ${creditPriceUsd.toLocaleString(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 4 })}
          </p>
        </div>
      )}

      {/* Reserves Info */}
      <div className="bg-gradient-to-br from-primary/10 to-secondary/10 rounded-3xl px-8 py-6 mb-8 w-full max-w-md">
        <h2 className="text-lg font-semibold mb-4 text-center">DEX Reserves</h2>
        <div className="flex justify-between items-center gap-4">
          <div className="text-center flex-1">
            <p className="text-sm text-base-content/60">Credits</p>
            <p className="text-2xl font-bold text-primary">{formatCredits(creditReserves)}</p>
          </div>
          <ArrowsRightLeftIcon className="h-6 w-6 text-base-content/40" />
          <div className="text-center flex-1">
            <p className="text-sm text-base-content/60">USDC</p>
            <p className="text-2xl font-bold text-secondary">{formatUsdc(assetReserves)}</p>
          </div>
        </div>
      </div>

      {/* User Balances */}
      <div className="bg-base-200 rounded-2xl px-6 py-4 mb-6 w-full max-w-md">
        <h3 className="text-sm font-medium text-base-content/60 mb-2">Your Balances</h3>
        <div className="flex justify-between">
          <span>
            Credits: <strong>{formatCredits(userCreditsBalance)}</strong>
          </span>
          <span>
            USDC: <strong>{formatUsdc(userUsdcBalance as bigint | undefined)}</strong>
          </span>
        </div>
      </div>

      {/* Main Content */}
      <div className="flex flex-col lg:flex-row gap-6 w-full max-w-4xl">
        {/* Liquidity Panel */}
        <div className="flex-1 bg-base-100 rounded-3xl p-6 shadow-lg border border-base-300">
          <h3 className="text-xl font-bold mb-4 flex items-center gap-2">
            <BanknotesIcon className="h-6 w-6" />
            Liquidity
          </h3>

          {!isInitialized ? (
            <div className="space-y-4">
              <div className="bg-warning/10 border border-warning/30 rounded-xl p-4">
                <p className="text-sm">DEX not initialized. Setup initial liquidity with:</p>
                <ul className="list-disc list-inside mt-2 text-sm">
                  <li>
                    <strong>100 Credits</strong>
                  </li>
                  <li>
                    <strong>1 USDC</strong>
                  </li>
                </ul>
              </div>
              <button
                className="btn btn-primary w-full"
                onClick={handleSetupLiquidity}
                disabled={isLoading || !connectedAddress}
              >
                {isLoading ? (
                  <span className="loading loading-spinner loading-sm"></span>
                ) : (
                  <PlusCircleIcon className="h-5 w-5" />
                )}
                Setup Initial Liquidity
              </button>
            </div>
          ) : (
            <div className="space-y-4">
              {/* User Liquidity Info */}
              <div className="bg-base-200 rounded-xl p-4">
                <p className="text-sm text-base-content/60">Your LP Tokens</p>
                <p className="text-2xl font-bold">{formatCredits(userLiquidity)}</p>
                {totalLiquidity && userLiquidity && totalLiquidity > BigInt(0) && (
                  <p className="text-sm text-base-content/60">
                    Share: {((Number(userLiquidity) / Number(totalLiquidity)) * 100).toFixed(2)}%
                  </p>
                )}
              </div>

              {/* Add Liquidity */}
              <div className="border-t border-base-300 pt-4">
                <h4 className="text-sm font-semibold mb-2 flex items-center gap-1">
                  <PlusCircleIcon className="h-4 w-4" />
                  Add Liquidity
                </h4>
                <div className="space-y-2">
                  <div>
                    <label className="text-xs text-base-content/60">Credits to deposit</label>
                    <input
                      type="number"
                      className="input input-bordered input-sm w-full"
                      placeholder="0.0"
                      value={depositAmount}
                      onChange={e => setDepositAmount(e.target.value)}
                    />
                  </div>
                  {depositAmount && requiredUsdcForDeposit && (
                    <p className="text-xs text-base-content/60">+ {formatUsdc(requiredUsdcForDeposit)} USDC required</p>
                  )}
                  <button
                    className="btn btn-primary btn-sm w-full"
                    onClick={handleDeposit}
                    disabled={isLoading || !depositAmount || !connectedAddress}
                  >
                    {isLoading ? (
                      <span className="loading loading-spinner loading-xs"></span>
                    ) : (
                      <PlusCircleIcon className="h-4 w-4" />
                    )}
                    Add Liquidity
                  </button>
                </div>
              </div>

              {/* Remove Liquidity */}
              <div className="border-t border-base-300 pt-4">
                <h4 className="text-sm font-semibold mb-2 flex items-center gap-1">
                  <MinusCircleIcon className="h-4 w-4" />
                  Remove Liquidity
                </h4>
                <div className="space-y-2">
                  <div>
                    <label className="text-xs text-base-content/60">LP tokens to withdraw</label>
                    <input
                      type="number"
                      className="input input-bordered input-sm w-full"
                      placeholder="0.0"
                      value={withdrawAmount}
                      onChange={e => setWithdrawAmount(e.target.value)}
                    />
                  </div>
                  {withdrawAmount &&
                    totalLiquidity &&
                    totalLiquidity > BigInt(0) &&
                    creditReserves &&
                    assetReserves && (
                      <p className="text-xs text-base-content/60">
                        Receive: ~{formatCredits((parseEther(withdrawAmount) * creditReserves) / totalLiquidity)}{" "}
                        Credits + ~{formatUsdc((parseEther(withdrawAmount) * assetReserves) / totalLiquidity)} USDC
                      </p>
                    )}
                  <button
                    className="btn btn-secondary btn-sm w-full"
                    onClick={handleWithdraw}
                    disabled={
                      isLoading || !withdrawAmount || !connectedAddress || !userLiquidity || userLiquidity === BigInt(0)
                    }
                  >
                    {isLoading ? (
                      <span className="loading loading-spinner loading-xs"></span>
                    ) : (
                      <MinusCircleIcon className="h-4 w-4" />
                    )}
                    Remove Liquidity
                  </button>
                </div>
              </div>
            </div>
          )}
        </div>

        {/* Swap Panel */}
        <div className="flex-1 bg-base-100 rounded-3xl p-6 shadow-lg border border-base-300">
          <h3 className="text-xl font-bold mb-4 flex items-center gap-2">
            <ArrowsRightLeftIcon className="h-6 w-6" />
            Swap
          </h3>

          {!isInitialized ? (
            <div className="text-center py-8 text-base-content/60">
              <p>Setup liquidity first to enable swaps</p>
            </div>
          ) : (
            <div className="space-y-4">
              {/* Swap Direction Toggle */}
              <div className="flex bg-base-200 rounded-xl p-1">
                <button
                  className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-all ${
                    swapDirection === "usdcToCredits" ? "bg-primary text-primary-content" : "hover:bg-base-300"
                  }`}
                  onClick={() => {
                    setSwapDirection("usdcToCredits");
                    setSwapAmount("");
                  }}
                >
                  USDC → Credits
                </button>
                <button
                  className={`flex-1 py-2 px-4 rounded-lg text-sm font-medium transition-all ${
                    swapDirection === "creditsToUsdc" ? "bg-primary text-primary-content" : "hover:bg-base-300"
                  }`}
                  onClick={() => {
                    setSwapDirection("creditsToUsdc");
                    setSwapAmount("");
                  }}
                >
                  Credits → USDC
                </button>
              </div>

              {/* Input */}
              <div>
                <label className="text-sm font-medium mb-1 block">
                  Amount ({swapDirection === "usdcToCredits" ? "USDC" : "Credits"})
                </label>
                <input
                  type="number"
                  className="input input-bordered w-full"
                  placeholder="0.0"
                  value={swapAmount}
                  onChange={e => setSwapAmount(e.target.value)}
                />
              </div>

              {/* Output Preview */}
              {swapAmount && swapOutput !== undefined && (
                <div className="bg-base-200 rounded-xl p-4">
                  <p className="text-sm text-base-content/60">You will receive (approx)</p>
                  <p className="text-xl font-bold">
                    {swapDirection === "usdcToCredits"
                      ? `${formatCredits(swapOutput)} Credits`
                      : `${formatUsdc(swapOutput)} USDC`}
                  </p>
                </div>
              )}

              {/* Swap Button */}
              <button
                className="btn btn-primary w-full"
                onClick={handleSwap}
                disabled={isLoading || !swapAmount || !connectedAddress}
              >
                {isLoading ? (
                  <span className="loading loading-spinner loading-sm"></span>
                ) : (
                  <ArrowsRightLeftIcon className="h-5 w-5" />
                )}
                Swap
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default DexPage;
