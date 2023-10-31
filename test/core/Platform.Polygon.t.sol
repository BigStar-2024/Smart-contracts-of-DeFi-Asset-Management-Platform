// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "../base/chains/PolygonSetup.sol";
import "../../src/core/libs/VaultTypeLib.sol";
import "../../src/interfaces/IVaultManager.sol";
import "../../src/interfaces/IHardWorker.sol";

contract PlatformPolygonTest is PolygonSetup {
    struct BuildingVars {
        uint len;
        uint paramsLen;
        string[] desc;
        string[] vaultType;
        string[] strategyId;
        uint[10][] initIndexes;
        address[] allVaultInitAddresses;
        uint[] allVaultInitNums;
        address[] allStrategyInitAddresses;
        uint[] allStrategyInitNums;
        int24[] allStrategyInitTicks;
    }

    constructor() {
        _init();
        deal(platform.buildingPayPerVaultToken(), address(this), 5e24);
        IERC20(platform.buildingPayPerVaultToken()).approve(address(factory), 5e24);

        deal(platform.allowedBBTokens()[0], address(this), 5e24);
        IERC20(platform.allowedBBTokens()[0]).approve(address(factory), 5e24);

        deal(PolygonLib.TOKEN_USDC, address(this), 1e12);
        IERC20(PolygonLib.TOKEN_USDC).approve(address(factory), 1e12);
    }

    function testUserBalance() public {
        (
            address[] memory token,
            uint[] memory tokenPrice,
            uint[] memory tokenUserBalance,
            address[] memory vault,
            uint[] memory vaultSharePrice,
            uint[] memory vaultUserBalance,
            address[] memory nft,
            uint[] memory nftUserBalance,
        ) = platform.getBalance(address(this));
        uint len = token.length;
        for (uint i; i < len; ++i) {
            assertNotEq(token[i], address(0));
            assertGt(tokenPrice[i], 0);
            if (token[i] == PolygonLib.TOKEN_USDC) {
                assertEq(tokenUserBalance[i], 1e12);
            } else if(token[i] == platform.allowedBBTokens()[0]) {
                assertEq(tokenUserBalance[i], 5e24);
            } else {
                assertEq(tokenUserBalance[i], 0);
            }
        }
        len = vault.length;
        for (uint i; i < len; ++i) {
            assertNotEq(vault[i], address(0));
            assertGt(vaultSharePrice[i], 0);
            assertEq(vaultUserBalance[i], 0);
        }
        len = nft.length;
        for (uint i; i < len; ++i) {
            assertNotEq(nft[i], address(0));
            assertEq(nftUserBalance[i], 0);
        }
        assertEq(nft[0], platform.buildingPermitToken());
        assertEq(nft[1], platform.vaultManager());
        assertEq(nft[2], platform.strategyLogic());
    }

    function testAll() public {
        platform.setAllowedBBTokenVaults(platform.allowedBBTokens()[0], 1e4);
        BuildingVars memory vars;
        {
            // this method used to avoid stack too deep
            (
                string[] memory desc,
                string[] memory vaultType,
                string[] memory strategyId,
                uint[10][] memory initIndexes,
                address[] memory allVaultInitAddresses,
                uint[] memory allVaultInitNums,
                address[] memory allStrategyInitAddresses,
                uint[] memory allStrategyInitNums,
                int24[] memory allStrategyInitTicks
            ) = factory.whatToBuild();
            vars.desc = desc;
            vars.vaultType = vaultType;
            vars.strategyId = strategyId;
            vars.initIndexes = initIndexes;
            vars.allVaultInitAddresses = allVaultInitAddresses;
            vars.allVaultInitNums = allVaultInitNums;
            vars.allStrategyInitAddresses = allStrategyInitAddresses;
            vars.allStrategyInitNums = allStrategyInitNums;
            vars.allStrategyInitTicks = allStrategyInitTicks;
        }
        
        uint len = vars.desc.length;
        assertGt(len, 0);
        assertEq(len, vars.vaultType.length);
        assertEq(len, vars.strategyId.length);
        assertEq(len, vars.initIndexes.length);

        console.log('whatToBuild:');
        for (uint i; i < len; ++i) {
            uint paramsLen = vars.initIndexes[i][1] - vars.initIndexes[i][0];
            address[] memory vaultInitAddresses = new address[](paramsLen);
            for (uint k; k < paramsLen; ++k) {
                vaultInitAddresses[k] = vars.allVaultInitAddresses[vars.initIndexes[i][0] + k];
            }
            paramsLen = vars.initIndexes[i][3] - vars.initIndexes[i][2];
            uint[] memory vaultInitNums = new uint[](paramsLen);
            for (uint k; k < paramsLen; ++k) {
                vaultInitNums[k] = vars.allVaultInitNums[vars.initIndexes[i][2] + k];
            }
            paramsLen = vars.initIndexes[i][5] - vars.initIndexes[i][4];
            address[] memory strategyInitAddresses = new address[](paramsLen);
            for (uint k; k < paramsLen; ++k) {
                strategyInitAddresses[k] = vars.allStrategyInitAddresses[vars.initIndexes[i][4] + k];
            }
            paramsLen = vars.initIndexes[i][7] - vars.initIndexes[i][6];
            uint[] memory strategyInitNums = new uint[](paramsLen);
            for (uint k; k < paramsLen; ++k) {
                strategyInitNums[k] = vars.allStrategyInitNums[vars.initIndexes[i][6] + k];
            }
            paramsLen = vars.initIndexes[i][9] - vars.initIndexes[i][8];
            int24[] memory strategyInitTicks = new int24[](paramsLen);
            for (uint k; k < paramsLen; ++k) {
                strategyInitTicks[k] = vars.allStrategyInitTicks[vars.initIndexes[i][8] + k];
            }

            string memory vaultInitSymbols = vaultInitAddresses.length > 0 ? string.concat(' ', CommonLib.implodeSymbols(vaultInitAddresses, '-')) : '';

            if (CommonLib.eq(vars.vaultType[i], VaultTypeLib.REWARDING)) {
                (vaultInitAddresses, vaultInitNums) = _getRewardingInitParams(vars.allVaultInitAddresses[vars.initIndexes[i][0]]);
            }

            if (CommonLib.eq(vars.vaultType[i], VaultTypeLib.REWARDING_MANAGED)) {
                (vaultInitAddresses, vaultInitNums) = _getRewardingManagedInitParams(vars.allVaultInitAddresses[vars.initIndexes[i][0]]);
            }

            console.log(string.concat(' Vault: ', vars.vaultType[i], vaultInitSymbols, '. Strategy: ', vars.desc[i]));

            factory.deployVaultAndStrategy(
                vars.vaultType[i],
                vars.strategyId[i],
                vaultInitAddresses,
                vaultInitNums,
                strategyInitAddresses,
                strategyInitNums,
                strategyInitTicks
            );
            vm.expectRevert('Factory: such vault already deployed');
            factory.deployVaultAndStrategy(
                vars.vaultType[i],
                vars.strategyId[i],
                vaultInitAddresses,
                vaultInitNums,
                strategyInitAddresses,
                strategyInitNums,
                strategyInitTicks
            );
        }

        (string[] memory descEmpty,,,,,,,,) = factory.whatToBuild();
        assertEq(descEmpty.length, 0);

        // deposit to all vaults
        {
            (
                address[] memory vaultAddress,
                string[] memory symbol,
                string[] memory _vaultType,
                string[] memory _strategyId,,
            ) = IVaultManager(platform.vaultManager()).vaults();
            console.log('Built:');
            for (uint i; i < vaultAddress.length; ++i) {
                assertGt(bytes(symbol[i]).length, 0);
                assertGt(bytes(_vaultType[i]).length, 0);
                assertGt(bytes(_strategyId[i]).length, 0);
                console.log(string.concat(' ', symbol[i]));

                _depositToVault(vaultAddress[i], 1e21);
            }
        }
        
        IHardWorker hw = IHardWorker(platform.hardWorker());
        bool canExec;
        bytes memory execPayload;
        (canExec, execPayload) = hw.checkerServer();
        assertEq(canExec, false);

        skip(1 days);

        (canExec, execPayload) = hw.checkerServer();
        assertEq(canExec, true);
        (bool success,) = address(hw).call(execPayload);
        // HardWorker: only dedicated senders
        assertEq(success, false);
        vm.expectRevert("Controllable: not governance and not multisig");
        hw.setDedicatedServerMsgSender(address(this), true);
        vm.prank(platform.multisig());
        hw.setDedicatedServerMsgSender(address(this), true);

        (success,) = address(hw).call(execPayload);
        assertEq(success, true);

        skip(1 days);

        (canExec, execPayload) = hw.checkerGelato();
        assertEq(canExec, true);
        vm.prank(hw.dedicatedGelatoMsgSender());
        (success,) = address(hw).call(execPayload);
        // HardWorker: not enough ETH"
        assertEq(success, false);
        vm.deal(address(hw), 2e18);
        vm.prank(hw.dedicatedGelatoMsgSender());
        (success,) = address(hw).call(execPayload);
        assertEq(success, true);
        assertGt(hw.gelatoBalance(), 0);

        for (uint i; i < len; ++i) {
            (canExec, execPayload) = hw.checkerServer();
            if (canExec) {
                (success,) = address(hw).call(execPayload);
                assertEq(success, true);
            } else {
                break;
            }
        }

        vm.prank(platform.multisig());
        hw.setDelays(1 hours, 2 hours);

        skip(1 hours);
        skip(100);
        (canExec,) = hw.checkerGelato();
        assertEq(canExec, false);
        (canExec,) = hw.checkerServer();
        assertEq(canExec, true);
        
    }

    function _depositToVault(address vault, uint assetAmountUsd) internal {
        IStrategy strategy = IVault(vault).strategy();
        address[] memory assets = strategy.assets();

        // get amounts for deposit
        uint[] memory depositAmounts = new uint[](assets.length);
        for (uint j; j < assets.length; ++j) {
            (uint price,) = IPriceReader(platform.priceReader()).getPrice(assets[j]);
            depositAmounts[j] = assetAmountUsd * 10 ** IERC20Metadata(assets[j]).decimals() / price;
            deal(assets[j], address(this), depositAmounts[j]);
            IERC20(assets[j]).approve(vault, depositAmounts[j]);
        }

        // deposit
        IVault(vault).depositAssets(assets, depositAmounts, 0);
    }

    function _getRewardingInitParams(address bbToken) internal view returns (
        address[] memory vaultInitAddresses,
        uint[] memory vaultInitNums
    ) {
        vaultInitAddresses = new address[](1);
        vaultInitAddresses[0] = bbToken;
        address[] memory defaultBoostRewardsTokensFiltered = platform.defaultBoostRewardTokensFiltered(bbToken);
        vaultInitNums = new uint[](1 + defaultBoostRewardsTokensFiltered.length);
        vaultInitNums[0] = 3000e18;
    }

    function _getRewardingManagedInitParams(address bbToken) internal pure returns (
        address[] memory vaultInitAddresses,
        uint[] memory vaultInitNums
    ) {
        vaultInitAddresses = new address[](3);
        vaultInitAddresses[0] = bbToken;
        vaultInitAddresses[1] = bbToken;
        vaultInitAddresses[2] = PolygonLib.TOKEN_USDC;
        vaultInitNums = new uint[](3 * 2);
        vaultInitNums[0] = 86_400 * 7;
        vaultInitNums[1] = 86_400 * 30;
        vaultInitNums[2] = 86_400 * 30;
        vaultInitNums[3] = 0;
        vaultInitNums[4] = 1000e6;
        vaultInitNums[5] = 50_000;
    }
}