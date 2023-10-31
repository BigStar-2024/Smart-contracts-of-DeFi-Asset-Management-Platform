// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test, console} from "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@solady/utils/LibString.sol";
import "../../src/core/RVault.sol";
import "../../src/core/RMVault.sol";
import "../base/Utils.sol";
import "../base/FullMockSetup.sol";

contract VaultManagerTest is Test, FullMockSetup, Utils {
    using LibString for string;
    CVault public vault;
    RVault public rVault;
    RMVault public rmVault;

    function setUp() public {
        builderPermitToken.mint();
        builderPayPerVaultToken.mint(1e24);
        builderPayPerVaultToken.approve(address(factory), 2**255);
        deal(address(tokenB), address(this), 1e24);
        deal(address(tokenC), address(this), 1e24);
        tokenB.approve(address(factory), 2**255);
        tokenC.approve(address(factory), 2**255);
        address[] memory addresses = new address[](3);
        addresses[1] = address(lp);
        addresses[2] = address(tokenA);
        uint[] memory nums = new uint[](0);
        int24[] memory ticks = new int24[](0);
        factory.deployVaultAndStrategy(VaultTypeLib.COMPOUNDING, StrategyIdLib.DEV, new address[](0), new uint[](0), addresses, nums, ticks);
        platform.setAllowedBBTokenVaults(address(tokenC), 100);
        address[] memory initVaultAddreses = new address[](1);
        initVaultAddreses[0] = address(tokenC);
        uint[] memory initVaultNums = new uint[](1);
        initVaultNums[0] = 3000e18;
        IERC20(platform.allowedBBTokens()[0]).approve(address(factory), initVaultNums[0] * 2);
        factory.deployVaultAndStrategy(VaultTypeLib.REWARDING, StrategyIdLib.DEV, initVaultAddreses, initVaultNums, addresses, nums, ticks);
        platform.addDefaultBoostRewardToken(address(tokenB));
        initVaultAddreses = new address[](2);
        initVaultAddreses[0] = address(tokenC);
        initVaultAddreses[1] = address(tokenB);
        initVaultNums = new uint[](4);
        initVaultNums[0] = 86_400;
        initVaultNums[1] = 86_400 * 30;
        initVaultNums[2] = 3000e18;
        initVaultNums[3] = 20_000;
        factory.deployVaultAndStrategy(VaultTypeLib.REWARDING_MANAGED, StrategyIdLib.DEV, initVaultAddreses, initVaultNums, addresses, nums, ticks);

        vault = CVault(payable(factory.deployedVault(0)));
        rVault = RVault(payable(factory.deployedVault(1)));
        rmVault = RMVault(payable(factory.deployedVault(2)));
    }

    function testSVG() public {
        address[] memory assets = new address[](2);
        assets[0] = address (tokenA);
        assets[1] = address (tokenB);
        uint[] memory amounts = new uint[](2);
        amounts[0] = 1000e18;
        amounts[1] = 1000e6;
        tokenA.mint(amounts[0] * 2);
        tokenB.mint(amounts[1] * 2);
        tokenA.approve(address(vault), amounts[0]);
        tokenB.approve(address(vault), amounts[1]);
        tokenA.approve(address(rVault), amounts[0]);
        tokenB.approve(address(rVault), amounts[1]);

        vault.depositAssets(assets, amounts, 0);
        rVault.depositAssets(assets, amounts, 0);

        (uint sharePrice, bool sharePriceTrusted) = vault.price();
        assertEq(sharePrice, 1e18); // $1
        assertEq(sharePriceTrusted, true);

        // increase share price
        tokenA.mint(777e18 * 2);
        tokenA.transfer(address(vault.strategy()), 777555555e12);
        tokenA.transfer(address(rVault.strategy()), 777555555e12);

        // set last hardwork apr
        MockStrategy(address(vault.strategy())).setLastApr(12_387);
        MockStrategy(address(rVault.strategy())).setLastApr(12_387);

        // set underlying and tokenB APRs
        address[] memory assetToSetApr = new address[](2);
        uint[] memory aprsToSet = new uint[](2);
        assetToSetApr[0] = address(lp);
        assetToSetApr[1] = address(tokenB);
        aprsToSet[0] = 4_013;
        aprsToSet[1] = 2_000;
        IAprOracle(platform.aprOracle()).setAprs(assetToSetApr, aprsToSet);

        // svg
        string memory name;
        string memory description;

        (name, description,) = writeNftSvgToFile(platform.vaultManager(), 0, "out/VaultManager_CVault.svg");
        assertEq(keccak256(bytes(name)), keccak256(bytes("Vault #0")));
        assertEq(keccak256(bytes(description)), keccak256(bytes("Vault Stability MOCKA-MOCKB Dev Alpha DeepSpaceSwap Farm Good Params")));
        // console.log(description);

        writeNftSvgToFile(platform.vaultManager(), 1, "out/VaultManager_RVault.svg");
        writeNftSvgToFile(platform.vaultManager(), 2, "out/VaultManager_RMVault.svg");
    }

    function testSetRevenueReceiver() public {
        IVaultManager vaultManager = IVaultManager(platform.vaultManager());
        vm.prank(address(1));
        vm.expectRevert("VaultManager: not owner");
        vaultManager.setRevenueReceiver(1, address(1));   
        //owner of tokenId 1
        vm.prank(address(0x62c20Aa1e0272312BC100b4e23B4DC1Ed96dD7D1));
        vaultManager.setRevenueReceiver(1, address(1));
        assertEq(vaultManager.getRevenueReceiver(1), address(1));
    }
}