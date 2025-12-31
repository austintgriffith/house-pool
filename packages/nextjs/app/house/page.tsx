"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import type { NextPage } from "next";
import { formatUnits, parseUnits } from "viem";
import { useAccount, useReadContract, useWriteContract } from "wagmi";
import { BanknotesIcon, ClockIcon, MinusCircleIcon, PlusCircleIcon, SparklesIcon } from "@heroicons/react/24/outline";
import { useDeployedContractInfo, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

// USDC has 6 decimals, HOUSE has 18 decimals
const USDC_DECIMALS = 6;
const HOUSE_DECIMALS = 18;

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

const HousePage: NextPage = () => {
  const { address: connectedAddress } = useAccount();

  // State for user inputs
  const [depositAmount, setDepositAmount] = useState("");
  const [withdrawShares, setWithdrawShares] = useState("");

  // Get contract info
  const { data: housePoolContract } = useDeployedContractInfo({ contractName: "HousePool" });

  // Read pool stats
  const { data: totalPool, refetch: refetchTotalPool } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "totalPool",
  });

  const { data: effectivePool, refetch: refetchEffectivePool } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "effectivePool",
  });

  const { data: sharePrice, refetch: refetchSharePrice } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "sharePrice",
  });

  const { data: canRoll, refetch: refetchCanRoll } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "canRoll",
  });

  const { data: totalSupply, refetch: refetchTotalSupply } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "totalSupply",
  });

  const { refetch: refetchTotalPendingShares } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "totalPendingShares",
  });

  // Read user balances
  const { data: userHouseBalance, refetch: refetchUserHouseBalance } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "balanceOf",
    args: [connectedAddress],
  });

  const { data: userUsdcValue, refetch: refetchUserUsdcValue } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "usdcValue",
    args: [connectedAddress],
  });

  const { data: userUsdcBalance, refetch: refetchUserUsdcBalance } = useReadContract({
    address: USDC_ADDRESS,
    abi: USDC_ABI,
    functionName: "balanceOf",
    args: connectedAddress ? [connectedAddress] : undefined,
  });

  // Read withdrawal request
  const { data: withdrawalRequest, refetch: refetchWithdrawalRequest } = useScaffoldReadContract({
    contractName: "HousePool",
    functionName: "getWithdrawalRequest",
    args: [connectedAddress],
  });

  // Write hooks
  const { writeContractAsync: writeHousePool, isPending: isHousePoolWritePending } = useScaffoldWriteContract({
    contractName: "HousePool",
  });

  const { writeContractAsync: writeUsdc, isPending: isUsdcWritePending } = useWriteContract();

  // Refetch all data
  const refetchAll = useCallback(() => {
    refetchTotalPool();
    refetchEffectivePool();
    refetchSharePrice();
    refetchCanRoll();
    refetchTotalSupply();
    refetchTotalPendingShares();
    refetchUserHouseBalance();
    refetchUserUsdcValue();
    refetchUserUsdcBalance();
    refetchWithdrawalRequest();
  }, [
    refetchTotalPool,
    refetchEffectivePool,
    refetchSharePrice,
    refetchCanRoll,
    refetchTotalSupply,
    refetchTotalPendingShares,
    refetchUserHouseBalance,
    refetchUserUsdcValue,
    refetchUserUsdcBalance,
    refetchWithdrawalRequest,
  ]);

  // Auto-refresh
  useEffect(() => {
    const interval = setInterval(refetchAll, 10000);
    return () => clearInterval(interval);
  }, [refetchAll]);

  // Handle deposit
  const handleDeposit = async () => {
    if (!depositAmount || !housePoolContract) return;

    try {
      const amountUsdc = parseUnits(depositAmount, USDC_DECIMALS);

      // Approve USDC
      await writeUsdc({
        address: USDC_ADDRESS,
        abi: USDC_ABI,
        functionName: "approve",
        args: [housePoolContract.address, amountUsdc],
      });

      // Deposit
      await writeHousePool({
        functionName: "deposit",
        args: [amountUsdc],
      });

      setDepositAmount("");
      refetchAll();
    } catch (error) {
      console.error("Deposit failed:", error);
    }
  };

  // Handle request withdrawal
  const handleRequestWithdrawal = async () => {
    if (!withdrawShares) return;

    try {
      const shares = parseUnits(withdrawShares, HOUSE_DECIMALS);

      await writeHousePool({
        functionName: "requestWithdrawal",
        args: [shares],
      });

      setWithdrawShares("");
      refetchAll();
    } catch (error) {
      console.error("Request withdrawal failed:", error);
    }
  };

  // Handle execute withdrawal
  const handleWithdraw = async () => {
    try {
      await writeHousePool({
        functionName: "withdraw",
      });

      refetchAll();
    } catch (error) {
      console.error("Withdraw failed:", error);
    }
  };

  // Handle cancel withdrawal
  const handleCancelWithdrawal = async () => {
    try {
      await writeHousePool({
        functionName: "cancelWithdrawal",
      });

      refetchAll();
    } catch (error) {
      console.error("Cancel withdrawal failed:", error);
    }
  };

  const isLoading = isHousePoolWritePending || isUsdcWritePending;

  // Format helpers
  const formatUsdc = (value: bigint | undefined) =>
    value ? parseFloat(formatUnits(value, USDC_DECIMALS)).toLocaleString(undefined, { maximumFractionDigits: 2 }) : "0";

  const formatHouse = (value: bigint | undefined) =>
    value
      ? parseFloat(formatUnits(value, HOUSE_DECIMALS)).toLocaleString(undefined, { maximumFractionDigits: 4 })
      : "0";

  const formatSharePrice = (value: bigint | undefined, pool: bigint | undefined) => {
    if (!value || !pool || pool === 0n) return "1.000000";
    const priceInUsdc = Number(value) / 1e6;
    return priceInUsdc.toFixed(6);
  };

  // Calculate HOUSE tokens for a given USDC amount
  const calculateHouseOut = (usdcAmount: string) => {
    if (!usdcAmount || parseFloat(usdcAmount) === 0) return "0";
    if (!totalPool || totalPool === 0n) {
      return parseFloat(usdcAmount).toFixed(4);
    }
    if (!sharePrice) return "0";
    return ((parseFloat(usdcAmount) * 1e6) / Number(sharePrice)).toFixed(4);
  };

  // Parse withdrawal request
  const hasWithdrawalRequest = withdrawalRequest && withdrawalRequest[0] > 0n;
  const withdrawalCanExecute = withdrawalRequest && withdrawalRequest[3];
  const withdrawalIsExpired = withdrawalRequest && withdrawalRequest[4];
  const withdrawalUnlockTime = withdrawalRequest ? new Date(Number(withdrawalRequest[1]) * 1000) : null;
  const withdrawalExpiryTime = withdrawalRequest ? new Date(Number(withdrawalRequest[2]) * 1000) : null;

  return (
    <div className="flex flex-col items-center pt-8 px-4 pb-12 min-h-screen bg-[radial-gradient(ellipse_at_top,_var(--tw-gradient-stops))] from-primary/10 via-base-100 to-base-100">
      <h1 className="text-5xl font-black mb-2 tracking-tight">
        <span className="bg-gradient-to-r from-violet-400 via-purple-500 to-fuchsia-500 bg-clip-text text-transparent">
          🏠 House Pool
        </span>
      </h1>
      <p className="text-base-content/60 mb-8 text-center max-w-md">
        Buy HOUSE tokens to own the casino. Your tokens grow in value as the house profits from gambling.
      </p>

      {/* Pool Stats */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-3 w-full max-w-4xl mb-8">
        <div className="bg-base-100/80 backdrop-blur rounded-2xl p-4 shadow-lg border border-base-300">
          <p className="text-xs text-base-content/50 uppercase tracking-wide">Total Pool</p>
          <p className="text-2xl font-bold text-primary">${formatUsdc(totalPool)}</p>
        </div>
        <div className="bg-base-100/80 backdrop-blur rounded-2xl p-4 shadow-lg border border-base-300">
          <p className="text-xs text-base-content/50 uppercase tracking-wide">Effective Pool</p>
          <p className="text-2xl font-bold text-secondary">${formatUsdc(effectivePool)}</p>
        </div>
        <div className="bg-base-100/80 backdrop-blur rounded-2xl p-4 shadow-lg border border-primary/30 ring-2 ring-primary/20">
          <p className="text-xs text-base-content/50 uppercase tracking-wide">HOUSE Price</p>
          <p className="text-2xl font-bold text-primary">${formatSharePrice(sharePrice, totalPool)}</p>
        </div>
        <div className="bg-base-100/80 backdrop-blur rounded-2xl p-4 shadow-lg border border-base-300">
          <p className="text-xs text-base-content/50 uppercase tracking-wide">Total Supply</p>
          <p className="text-2xl font-bold">{formatHouse(totalSupply)}</p>
        </div>
        <div className="bg-base-100/80 backdrop-blur rounded-2xl p-4 shadow-lg border border-base-300">
          <p className="text-xs text-base-content/50 uppercase tracking-wide">Can Roll?</p>
          <p className={`text-2xl font-bold ${canRoll ? "text-success" : "text-error"}`}>
            {canRoll ? "Yes ✓" : "No ✗"}
          </p>
        </div>
      </div>

      {/* User Position */}
      {connectedAddress && (
        <div className="bg-gradient-to-br from-violet-500/10 to-fuchsia-500/10 rounded-3xl p-6 w-full max-w-4xl mb-8 border border-violet-500/20">
          <h2 className="text-lg font-bold mb-4 flex items-center gap-2">
            <BanknotesIcon className="h-5 w-5" />
            Your Position
          </h2>
          <div className="grid grid-cols-3 gap-4">
            <div className="bg-base-100/50 rounded-xl p-4">
              <p className="text-sm text-base-content/60">HOUSE Tokens</p>
              <p className="text-2xl font-bold">{formatHouse(userHouseBalance)}</p>
            </div>
            <div className="bg-base-100/50 rounded-xl p-4">
              <p className="text-sm text-base-content/60">USDC Value</p>
              <p className="text-2xl font-bold text-primary">${formatUsdc(userUsdcValue)}</p>
            </div>
            <div className="bg-base-100/50 rounded-xl p-4">
              <p className="text-sm text-base-content/60">Wallet USDC</p>
              <p className="text-2xl font-bold">${formatUsdc(userUsdcBalance as bigint | undefined)}</p>
            </div>
          </div>
        </div>
      )}

      {/* Buy/Sell Panel */}
      <div className="bg-base-100 rounded-3xl p-6 shadow-xl border border-base-300 w-full max-w-lg mb-8">
        <h3 className="text-xl font-bold mb-5 flex items-center gap-2">
          <PlusCircleIcon className="h-6 w-6 text-primary" />
          Buy & Sell HOUSE
        </h3>

        {/* Buy Section */}
        <div className="space-y-3 mb-6">
          <h4 className="text-sm font-semibold text-base-content/80">Buy HOUSE</h4>
          <input
            type="number"
            className="input input-bordered w-full"
            placeholder="USDC to spend"
            value={depositAmount}
            onChange={e => setDepositAmount(e.target.value)}
          />
          {depositAmount && <p className="text-sm text-base-content/60">≈ {calculateHouseOut(depositAmount)} HOUSE</p>}
          <button
            className="btn btn-primary w-full"
            onClick={handleDeposit}
            disabled={isLoading || !depositAmount || !connectedAddress}
          >
            {isLoading ? <span className="loading loading-spinner loading-sm"></span> : "Buy HOUSE"}
          </button>
        </div>

        {/* Sell Section */}
        <div className="space-y-3 border-t border-base-300 pt-5">
          <h4 className="text-sm font-semibold text-base-content/80 flex items-center gap-2">
            <MinusCircleIcon className="h-4 w-4" />
            Sell HOUSE
          </h4>

          {hasWithdrawalRequest ? (
            <div className="bg-base-200 rounded-xl p-4 space-y-3">
              <div className="flex justify-between items-center">
                <span className="text-sm">Pending Sale</span>
                <span className="font-bold">{formatHouse(withdrawalRequest[0])} HOUSE</span>
              </div>

              {withdrawalIsExpired ? (
                <div className="text-error text-sm">Sale expired. Please try again.</div>
              ) : withdrawalCanExecute ? (
                <>
                  <div className="text-success text-sm font-semibold">Ready to confirm sale!</div>
                  <div className="text-xs text-base-content/60">Expires: {withdrawalExpiryTime?.toLocaleString()}</div>
                </>
              ) : (
                <div className="text-warning text-sm flex items-center gap-1">
                  <ClockIcon className="h-4 w-4" />
                  Confirm available: {withdrawalUnlockTime?.toLocaleString()}
                </div>
              )}

              <div className="flex gap-2">
                <button
                  className="btn btn-secondary flex-1"
                  onClick={handleWithdraw}
                  disabled={isLoading || !withdrawalCanExecute}
                >
                  Confirm Sale
                </button>
                <button className="btn btn-outline" onClick={handleCancelWithdrawal} disabled={isLoading}>
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <>
              <div className="flex gap-2">
                <input
                  type="number"
                  className="input input-bordered flex-1"
                  placeholder="HOUSE tokens to sell"
                  value={withdrawShares}
                  onChange={e => setWithdrawShares(e.target.value)}
                />
                <button
                  className="btn btn-ghost btn-sm self-center"
                  onClick={() => userHouseBalance && setWithdrawShares(formatUnits(userHouseBalance, HOUSE_DECIMALS))}
                  disabled={!userHouseBalance}
                >
                  MAX
                </button>
              </div>
              {withdrawShares && (
                <p className="text-sm text-base-content/60">
                  ≈ $
                  {!totalPool || totalPool === 0n
                    ? parseFloat(withdrawShares).toFixed(2)
                    : ((parseFloat(withdrawShares) * Number(sharePrice)) / 1e6).toFixed(2)}{" "}
                  USDC
                </p>
              )}
              <p className="text-xs text-base-content/50">10 sec cooldown, then 1 min to confirm</p>
              <button
                className="btn btn-secondary w-full"
                onClick={handleRequestWithdrawal}
                disabled={isLoading || !withdrawShares || !connectedAddress}
              >
                Sell HOUSE
              </button>
            </>
          )}
        </div>
      </div>

      {/* Link to Roll */}
      <div className="text-center pb-8">
        <p className="text-base-content/50 mb-3">Want to gamble against the house?</p>
        <Link href="/" className="btn btn-outline gap-2">
          <SparklesIcon className="h-5 w-5" />
          Roll the Dice
        </Link>
      </div>

      {/* Info Footer */}
      <div className="text-center text-sm text-base-content/40 max-w-xl px-4">
        <p>
          <strong>How it works:</strong> Buy HOUSE tokens to own a share of the casino. As gamblers play and lose, the
          pool grows and HOUSE price increases. The house has a ~9% edge.
        </p>
        <p className="mt-2">Selling requires a 10-second cooldown to prevent front-running.</p>
      </div>
    </div>
  );
};

export default HousePage;
