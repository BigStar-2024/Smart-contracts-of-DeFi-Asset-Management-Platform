// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../core/libs/ConstantsLib.sol";
import "../../core/libs/VaultTypeLib.sol";
import "../../core/libs/CommonLib.sol";
import "../../interfaces/IPlatform.sol";
import "../../interfaces/IVault.sol";
import "../../interfaces/IVaultManager.sol";
import "../../interfaces/IStrategyLogic.sol";
import "../../interfaces/IFactory.sol";
import "../../interfaces/IPriceReader.sol";
import "../../interfaces/ISwapper.sol";
import "../../interfaces/ILPStrategy.sol";
import "../../interfaces/IRVault.sol";

library StrategyLib {
    using SafeERC20 for IERC20;

    event HardWork(uint apr, uint compoundApr, uint earned, uint tvl, uint duration, uint sharePrice);
    event ExtractFees(uint vaultManagerReceiverFee, uint strategyLogicReceiverFee, uint ecosystemRevenueReceiverFee, uint multisigReceiverFee);

    struct ExtractFeesVars {
        IPlatform platform;
        uint feePlatform;
        uint amountPlatform;
        uint feeShareVaultManager;
        uint amountVaultManager;
        uint feeShareStrategyLogic;
        uint amountStrategyLogic;
        uint feeShareEcosystem;
        uint amountEcosystem;
    }

    function FarmingStrategyBase_init(string memory id, address platform, uint farmId) external returns (address[] memory rewardAssets) {
        IFactory.Farm memory farm = IFactory(IPlatform(platform).factory()).farm(farmId);
        require (keccak256(bytes(farm.strategyLogicId)) == keccak256(bytes(id)), "FarmingStrategyBase: incorrect strategy id");
        uint len = farm.rewardAssets.length;
        address swapper = IPlatform(platform).swapper();
        for (uint i; i < len; ++i) {
            IERC20(farm.rewardAssets[i]).forceApprove(swapper, type(uint).max);
        }
        rewardAssets = farm.rewardAssets;
    }

    function transferAssets(
        address[] memory assets,
        uint amount,
        uint total_,
        address receiver
    ) external returns (uint[] memory amountsOut) {
        uint len = assets.length;
        amountsOut = new uint[](len);
        for (uint i; i < len; ++i) {
            amountsOut[i] = IERC20(assets[i]).balanceOf(address(this)) * amount / total_;
            amountsOut[i] = IERC20(assets[i]).balanceOf(address(this)) * amount / total_;
            IERC20(assets[i]).transfer(receiver, amountsOut[i]);
        }
    }

    function extractFees(
        address platform,
        address vault,
        string memory _id,
        address[] memory assets_,
        uint[] memory amounts_
    ) external returns(uint[] memory amountsRemaining) {
        ExtractFeesVars memory vars = ExtractFeesVars({
            platform: IPlatform(platform),
            feePlatform: 0,
            amountPlatform: 0,
            feeShareVaultManager: 0,
            amountVaultManager: 0,
            feeShareStrategyLogic: 0,
            amountStrategyLogic: 0,
            feeShareEcosystem: 0,
            amountEcosystem: 0
        });
        // IPlatform _platform = IPlatform(platform);
        // uint[] memory fees = new uint[](4);
        // uint[] memory feeAmounts = new uint[](4);
        (vars.feePlatform, vars.feeShareVaultManager, vars.feeShareStrategyLogic, vars.feeShareEcosystem) = vars.platform.getFees();
        address vaultManagerReceiver = IVaultManager(vars.platform.vaultManager()).getRevenueReceiver(IVault(vault).tokenId());
        //slither-disable-next-line unused-return
        (,,,,,uint strategyLogicTokenId) = IFactory(vars.platform.factory()).strategyLogicConfig(keccak256(bytes(_id)));
        address strategyLogicReceiver = IStrategyLogic(vars.platform.strategyLogic()).getRevenueReceiver(strategyLogicTokenId);
        uint len = assets_.length;
        amountsRemaining = new uint[](len);
        for (uint i; i < len; ++i) {
            if (amounts_[i] > 0) {
                // revenue fee amount of assets_[i]
                vars.amountPlatform = amounts_[i] * vars.feePlatform / ConstantsLib.DENOMINATOR;

                amountsRemaining[i] = amounts_[i] - vars.amountPlatform;

                // VaultManager amount
                vars.amountVaultManager = vars.amountPlatform * vars.feeShareVaultManager / ConstantsLib.DENOMINATOR;

                // StrategyLogic amount
                vars.amountStrategyLogic = vars.amountPlatform * vars.feeShareStrategyLogic / ConstantsLib.DENOMINATOR;

                // Ecosystem amount
                vars.amountEcosystem = vars.amountPlatform  * vars.feeShareEcosystem / ConstantsLib.DENOMINATOR;

                // Multisig share and amount
                uint multisigShare = ConstantsLib.DENOMINATOR - vars.feeShareVaultManager - vars.feeShareStrategyLogic - vars.feeShareEcosystem;
                uint multisigAmount = multisigShare > 0 ? vars.amountPlatform  - vars.amountVaultManager - vars.amountStrategyLogic - vars.amountEcosystem : 0;

                // send amounts
                IERC20(assets_[i]).safeTransfer(vaultManagerReceiver, vars.amountVaultManager);
                IERC20(assets_[i]).safeTransfer(strategyLogicReceiver, vars.amountStrategyLogic);
                if (vars.amountEcosystem > 0) {
                    IERC20(assets_[i]).safeTransfer(vars.platform.ecosystemRevenueReceiver(), vars.amountEcosystem);
                }
                if (multisigAmount > 0) {
                    IERC20(assets_[i]).safeTransfer(vars.platform.multisig(), multisigAmount);
                }
                emit ExtractFees(vars.amountVaultManager, vars.amountStrategyLogic, vars.amountEcosystem, multisigAmount);
            }
        }
    }

    function liquidateRewards(address platform, address exchangeAsset, address[] memory rewardAssets_, uint[] memory rewardAmounts_) external returns (uint earnedExchangeAsset) {
        ISwapper swapper = ISwapper(IPlatform(platform).swapper());
        uint len = rewardAssets_.length;
        uint exchangeAssetBalanceBefore = balance(exchangeAsset);
        for (uint i; i < len; ++i) {
            if (rewardAmounts_[i] > swapper.threshold(rewardAssets_[i])) {
                swapper.swap(rewardAssets_[i], exchangeAsset, rewardAmounts_[i], ConstantsLib.SWAP_REVENUE_PRICE_IMPACT_TOLERANCE);
            }
        }
        uint exchangeAssetBalanceAfter = balance(exchangeAsset);
        earnedExchangeAsset = exchangeAssetBalanceAfter - exchangeAssetBalanceBefore;
    }

    function emitApr(
        uint lastHardWork,
        address platform,
        address[] memory assets,
        uint[] memory amounts,
        uint tvl,
        uint totalBefore,
        uint totalAfter,
        address vault
    ) external returns(uint apr, uint aprCompound) {
        uint duration = block.timestamp - lastHardWork;
        IPriceReader priceReader = IPriceReader(IPlatform(platform).priceReader());
        //slither-disable-next-line unused-return
        (uint earned,,) = priceReader.getAssetsPrice(assets, amounts);
        apr = computeApr(tvl, earned, duration);
        aprCompound = computeApr(totalBefore, totalAfter - totalBefore, duration);
        uint sharePrice = tvl * 1e18 / IERC20(vault).totalSupply();
        emit HardWork(apr, aprCompound, earned, tvl, duration, sharePrice);
    }

    function balance(address token) public view returns (uint) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev https://www.investopedia.com/terms/a/apr.asp
    ///      TVL and rewards should be in the same currency and with the same decimals
    function computeApr(uint tvl, uint earned, uint duration) public pure returns (uint) {
        if (tvl == 0 || duration == 0) {
            return 0;
        }
        return earned * 1e18 * ConstantsLib.DENOMINATOR * uint(365) / tvl / (duration * 1e18 / 1 days);
    }

    function revertUnderlying(address underlying) external pure {
        revert(underlying == address(0) ? 'StrategyBase: no underlying' : 'StrategyBase: not implemented');
    }

    function assetsAmountsWithBalances(address[] memory assets_, uint[] memory amounts_) external view returns (address[] memory assets, uint[] memory amounts) {
        assets = assets_;
        amounts = amounts_;
        uint len = assets_.length;
        for (uint i; i < len; ++i) {
            amounts[i] += balance(assets_[i]);
        }
    }

    // function getFarmsForStrategyId(address platform, string memory _id) external view returns (IFactory.Farm[] memory farms) {
    //     uint total;
    //     IFactory.Farm[] memory allFarms = IFactory(IPlatform(platform).factory()).farms();
    //     uint len = allFarms.length;
    //     for (uint i; i < len; ++i) {
    //         IFactory.Farm memory farm = allFarms[i];
    //         if (farm.status == 0 && CommonLib.eq(farm.strategyLogicId, _id)) {
    //             total++;
    //         }
    //     }
    //     farms = new IFactory.Farm[](total);
    //     uint k;
    //     for (uint i; i < len; ++i) {
    //         IFactory.Farm memory farm = allFarms[i];
    //         if (farm.status == 0 && CommonLib.eq(farm.strategyLogicId, _id)) {
    //             farms[k] = farm;
    //             k++;
    //         }
    //     }
    // }

}
