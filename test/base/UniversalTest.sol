// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./ChainSetup.sol";
import "./Utils.sol";
import "../../src/core/libs/VaultTypeLib.sol";
import "../../src/strategies/libs/StrategyDeveloperLib.sol";
import "../../src/interfaces/ISwapper.sol";
import "../../src/interfaces/IFactory.sol";
import "../../src/interfaces/IStrategy.sol";
import "../../src/interfaces/IStrategyLogic.sol";
import "../../src/interfaces/IVault.sol";
import "../../src/interfaces/IRVault.sol";
import "../../src/interfaces/IPriceReader.sol";
import "../../src/interfaces/IFarmingStrategy.sol";
import "../../src/interfaces/IPairStrategyBase.sol";
import "../../src/interfaces/IHardWorker.sol";

abstract contract UniversalTest is Test, ChainSetup, Utils {
    Strategy[] public strategies;
    string public strategyId;

    struct Strategy {
        string id;
        address pool;
        uint farmId;
        address underlying;
    }
    struct TestStrategiesVars {
        address[] allowedBBTokens;
        address strategyLogic;
        address strategyImplementation;
        bool farming;
        uint tokenId;
        string[] types;
        IHardWorker hardWorker;
        address vault;
        address[] vaultsForHardWork;
        bool isRVault;
        bool isRMVault;
        uint apr;
        uint aprCompound;
        uint earned;
        uint duration;
        Vm.Log[] entries;
        address dexAdapter;
        address pool;
    }

    modifier universalTest() {
        _init();
        _;
        _testStrategies();
    }

    function testNull() public {}

    function _testStrategies() internal {
        console.log(string.concat('Universal test of strategy logic', strategyId));

        deal(platform.buildingPayPerVaultToken(), address(this), 5e24);
        IERC20(platform.buildingPayPerVaultToken()).approve(address(factory), 5e24);
        TestStrategiesVars memory vars;
        vars.hardWorker = IHardWorker(platform.hardWorker());
        vm.prank(platform.governance());
        vars.hardWorker.setDedicatedServerMsgSender(address(this), true);
        vars.vaultsForHardWork = new address[](1);
        vars.allowedBBTokens = platform.allowedBBTokens();
        platform.setAllowedBBTokenVaults(vars.allowedBBTokens[0], 1e6);
        vars.strategyLogic = platform.strategyLogic();
        for (uint i; i < strategies.length; ++i) {
            assertNotEq(StrategyDeveloperLib.getDeveloper(strategies[i].id), address(0), "Universal test: put your address to StrategyDeveloperLib");
            (,vars.strategyImplementation,,,vars.farming, vars.tokenId) = factory.strategyLogicConfig(keccak256(bytes(strategies[i].id)));
            writeNftSvgToFile(vars.strategyLogic, vars.tokenId, string.concat("out/StrategyLogic_", strategies[i].id, ".svg"));
            vars.types = IStrategy(vars.strategyImplementation).supportedVaultTypes();

            for (uint k; k < vars.types.length; ++k) {
                vars.isRVault = CommonLib.eq(vars.types[k], VaultTypeLib.REWARDING);
                vars.isRMVault = CommonLib.eq(vars.types[k], VaultTypeLib.REWARDING_MANAGED);
                {
                    address[] memory vaultInitAddresses = new address[](0);
                    uint[] memory vaultInitNums = new uint[](0);
                    if (vars.isRVault) {
                        vaultInitAddresses = new address[](1);
                        vaultInitAddresses[0] = vars.allowedBBTokens[0];
                        vaultInitNums = new uint[](1 + platform.defaultBoostRewardTokensFiltered(vars.allowedBBTokens[0]).length);
                        vaultInitNums[0] = 3000e18; // 3k PROFIT
                        deal(vaultInitAddresses[0], address(this), 3000e18);
                        IERC20(vaultInitAddresses[0]).approve(address(factory), 3000e18);
                    }
                    if (vars.isRMVault) {
                        vaultInitAddresses = new address[](2);
                        uint vaultInitAddressesLength = vaultInitAddresses.length;
                        // bbToken
                        vaultInitAddresses[0] = vars.allowedBBTokens[0];
                        // boost reward tokens
                        vaultInitAddresses[1] = platform.targetExchangeAsset();
                        vaultInitNums = new uint[](vaultInitAddressesLength * 2);
                        // bbToken vesting duration
                        vaultInitNums[0] = 3600;
                        for (uint e = 1; e < vaultInitAddressesLength; ++e) {
                            vaultInitNums[e] = 86400 * 30;
                            vaultInitNums[e + vaultInitAddressesLength - 1] = 1000e6; // 1000 usdc
                            deal(vaultInitAddresses[e], address(this), 1000e6);
                            IERC20(vaultInitAddresses[e]).approve(address(factory), 1000e6);
                        }
                        // compoundRatuo
                        vaultInitNums[vaultInitAddressesLength * 2 - 1] = 50_000;
                    }

                    if (!vars.farming) {
                        revert("UniversalTest: only farming strategies supported yet");
                    }

                    address[] memory initStrategyAddresses = new address[](0);
                    uint[] memory nums = new uint[](1);
                    nums[0] = strategies[i].farmId;
                    int24[] memory ticks = new int24[](0);
                    factory.deployVaultAndStrategy(vars.types[k], strategies[i].id, vaultInitAddresses, vaultInitNums, initStrategyAddresses, nums, ticks);

                    assertEq(IERC721(platform.vaultManager()).ownerOf(i), address (this));
                }

                vars.vault = factory.deployedVault(factory.deployedVaultsLength() - 1);
                vars.vaultsForHardWork[0] = vars.vault;
                IStrategy strategy = IVault(vars.vault).strategy();
                address[] memory assets = strategy.assets();
                vars.dexAdapter = address(IPairStrategyBase(address(strategy)).dexAdapter());
                vars.pool = IPairStrategyBase(address (strategy)).pool();
                console.log(string.concat(IERC20Metadata(vars.vault).symbol(),' [Compound ratio: ', vars.isRVault || vars.isRMVault ? CommonLib.u2s(IRVault(vars.vault).compoundRatio() / 1000) : '100', '%]. Name: ', IERC20Metadata(vars.vault).name(), "."));

                if (vars.farming) {
                    assertEq(IFarmingStrategy(address(strategy)).canFarm(), true);
                }

                // todo loop

                // get amounts for deposit
                uint[] memory depositAmounts = new uint[](assets.length);
                for (uint j; j < assets.length; ++j) {
                    (uint price,) = IPriceReader(platform.priceReader()).getPrice(assets[j]);

                    require (price > 0, "UniversalTest: price is zero. Forget to add swapper routes?");
                    depositAmounts[j] = 1000 * 10 ** IERC20Metadata(assets[j]).decimals() * 1e18 / price;
                    deal(assets[j], address(this), depositAmounts[j]);
                    IERC20(assets[j]).approve(vars.vault, depositAmounts[j]);
                }

                // deposit
                IVault(vars.vault).depositAssets(assets, depositAmounts, 0);
                (uint tvl, ) = IVault(vars.vault).tvl();
                assertGt(tvl, 0, "Universal test: tvl is zero");

                skip(6 hours);

                // pool swap volume
                {
                    ISwapper swapper = ISwapper(platform.swapper());
                    ISwapper.PoolData[] memory poolData = new ISwapper.PoolData[](1);
                    poolData[0].pool = vars.pool;
                    poolData[0].dexAdapter = vars.dexAdapter;
                    poolData[0].tokenIn = assets[0];
                    poolData[0].tokenOut = assets[1];
                    IERC20(assets[0]).approve(address(swapper), depositAmounts[0]);
                    deal(assets[0], address(this), depositAmounts[0]);
                    swapper.swapWithRoute(poolData, depositAmounts[0], 1_000);
                }

                skip(6 hours);

                {
                    (address[] memory __assets, uint[] memory amounts) = strategy.getRevenue();
                    (uint totalRevenueUSD,,) = IPriceReader(platform.priceReader()).getAssetsPrice(__assets, amounts);
                    assertGt(totalRevenueUSD, 0, "Universal test: estimated totalRevenueUSD is zero");
                    if (totalRevenueUSD == 0) {
                        for (uint x; x < __assets.length; ++x) {
                            console.log(string.concat('__assets[',Strings.toString(x),']:'), IERC20Metadata(__assets[x]).symbol());
                            console.log(string.concat(' amounts[',Strings.toString(x),']:'), amounts[x]);
                        }
                    }
                }

                vm.txGasPrice(15e10); // 150gwei

                {
                    vars.apr = 0;
                    vars.aprCompound = 0;
                    vars.earned = 0;
                    vars.duration = 0;
                    vm.recordLogs();
                    vars.hardWorker.call(vars.vaultsForHardWork);
                    // IVault(vault).doHardWork();
                    vars.entries = vm.getRecordedLogs();
                    for (uint j = 0; j < vars.entries.length; ++j) {
                        if (vars.entries[j].topics[0] == keccak256("HardWork(uint256,uint256,uint256,uint256,uint256)")) {
                            (vars.apr, vars.aprCompound, vars.earned, tvl, vars.duration) = abi.decode(vars.entries[j].data, (uint, uint, uint, uint, uint));

                            console.log(string.concat(
                                '    APR: ', CommonLib.formatApr(vars.apr),
                                '. APR compound: ', CommonLib.formatApr(vars.aprCompound),
                                '. Earned: ', CommonLib.formatUsdAmount(vars.earned),
                                '. TVL: ', CommonLib.formatUsdAmount(tvl),
                                '. Duration: ', Strings.toString(vars.duration),
                                '.'
                            ));

                            assertGt(vars.apr, 0);
                            assertGt(vars.earned, 0);
                            assertGt(tvl, 0);
                            assertGt(vars.duration, 0);
                        }
                    }
                }

                if (vars.isRVault || vars.isRMVault) {
                    address rewardToken = vars.isRVault ? vars.allowedBBTokens[0] : platform.targetExchangeAsset();
                    uint balanceBefore = IERC20(rewardToken).balanceOf(address(this));
                    IRVault(vars.vault).getAllRewards();
                    assertGt(IERC20(rewardToken).balanceOf(address(this)), balanceBefore);
                    skip(3600);
                    balanceBefore = IERC20(rewardToken).balanceOf(address(this));
                    IRVault(vars.vault).getAllRewards();
                    assertGt(IERC20(rewardToken).balanceOf(address(this)), balanceBefore);
                }

                uint totalWas = strategy.total();

                vm.roll(block.number + 6);

                IVault(vars.vault).withdrawAssets(assets, IERC20(vars.vault).balanceOf(address(this)), new uint[](2));

                // test underlying and hardwork on deposit
                address underlying = strategy.underlying();
                if (underlying != address(0)) {
                    skip(7200);
                    deal(underlying, address(this), totalWas);
                    assertEq(IERC20(underlying).balanceOf(address(this)), totalWas);
                    IERC20(underlying).approve(vars.vault, totalWas);
                    address[] memory underlyingAssets = new address[](1);
                    underlyingAssets[0] = underlying;
                    uint[] memory underlyingAmounts = new uint[](1);
                    underlyingAmounts[0] = totalWas;
                    (, uint sharesOut, uint valueOut) = IVault(vars.vault).previewDepositAssets(underlyingAssets, underlyingAmounts);
                    assertEq(valueOut, totalWas);
                    uint lastHw = strategy.lastHardWork();
                    IVault(vars.vault).depositAssets(underlyingAssets, underlyingAmounts, 0);
                    assertGt(strategy.lastHardWork(), lastHw);
                    assertEq(IERC20(underlying).balanceOf(address(this)), 0);
                    assertGt(strategy.total(), totalWas);
                    uint vaultBalance = IERC20(vars.vault).balanceOf(address(this));
                    assertEq(vaultBalance, sharesOut);
                    uint[] memory minAmounts = new uint[](1);
                    minAmounts[0] = totalWas - 1;
                    vm.expectRevert(bytes("Vault: wait few blocks"));
                    IVault(vars.vault).withdrawAssets(underlyingAssets, vaultBalance, minAmounts);
                    vm.roll(block.number + 6);
                    IVault(vars.vault).withdrawAssets(underlyingAssets, vaultBalance, minAmounts);
                    assertGe(IERC20(underlying).balanceOf(address(this)), totalWas - 1);
                    assertLe(IERC20(underlying).balanceOf(address(this)), totalWas + 1);
                }
            }
        }
    }
}