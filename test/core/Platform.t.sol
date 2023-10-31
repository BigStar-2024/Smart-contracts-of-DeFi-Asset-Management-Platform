// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {Test, console} from "forge-std/Test.sol";
import {Platform} from "../../src/core/Platform.sol";
import "../../src/core/proxy/Proxy.sol";
import "../../src/core/CVault.sol";
import "../../src/test/MockVaultUpgrade.sol";
import "../../src/core/Factory.sol";

contract PlatformTest is Test {
    Platform public platform;

    function setUp() public {
        Proxy proxy = new Proxy();
        proxy.initProxy(address(new Platform()));
        platform = Platform(address(proxy));
    }

    function testSetup() public {
        platform.initialize(address(this), '23.11.0-dev');
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        platform.initialize(address(this), '23.11.0-dev');
        assertEq(platform.governance(), address(0));
        assertEq(platform.multisig(), address(this));
        Proxy proxy = new Proxy();
        proxy.initProxy(address(new Platform()));
        Platform platform2 = Platform(address(proxy));
        platform2.initialize(address(this),  '23.11.0-dev');
        platform.setup(
            IPlatform.SetupAddresses({
                factory: address(1),
                priceReader: address(2),
                swapper: address(3),
                buildingPermitToken: address(4),
                buildingPayPerVaultToken: address(5),
                vaultManager: address(6),
                strategyLogic: address(7),
                aprOracle: address(8),
                targetExchangeAsset: address(9),
                hardWorker: address(10)
            }),
            IPlatform.PlatformSettings({
                networkName: 'Localhost Ethereum',
                networkExtra: CommonLib.bytesToBytes32(abi.encodePacked(bytes3(0x7746d7), bytes3(0x040206))),
                fee: 6_000,
                feeShareVaultManager: 30_000,
                feeShareStrategyLogic: 30_000,
                feeShareEcosystem: 0,
                minInitialBoostPerDay: 30e18, // $30
                minInitialBoostDuration: 30 * 86400 // 30 days
            })
        );
    }

    function testAddRemoveOperator(address operator) public {
        platform.initialize(address(this), '23.11.0-dev');
        if (operator == address(this)) {
            vm.expectRevert("Platform: EXIST");
        } else {
            assertEq(platform.isOperator(operator), false);
        }

        platform.addOperator(operator);
        
        assertEq(platform.isOperator(operator), true);
        address[] memory operatorsList = platform.operatorsList();

        if (operator == address(this)) {
            assertEq(operatorsList.length, 1);
        } else {
            assertEq(operatorsList.length, 2);
        }

        platform.removeOperator(operator);
        assertEq(platform.isOperator(operator), false);

        if (operator != address(0) && operator != address(this)) {
            vm.startPrank(operator);
            vm.expectRevert(bytes("Controllable: not governance and not multisig"));
            platform.addOperator(operator);
            vm.stopPrank();
        }
    }

    function testProxyUpgrade(address multisig) public {
        if (multisig != address(0)) {
            platform.initialize(multisig, '23.11.0-dev');

            // its not fabric vault
            CVault vaultImplementation = new CVault();

            MockVaultUpgrade vaultImplementationUpgrade = new MockVaultUpgrade();

            Proxy proxy = new Proxy();
            proxy.initProxy(address(vaultImplementation));
            CVault vault = CVault(payable(address(proxy)));
            vault.initialize(address(platform), address(0), 'V', 'V', 0, new address[](0), new uint[](0));

            address[] memory proxies = new address[](1);
            proxies[0] = address(proxy);
            address[] memory implementations = new address[](1);
            implementations[0] = address(vaultImplementationUpgrade);

            if (multisig != address(this)) {
                vm.expectRevert(bytes("Controllable: not governance and not multisig"));
                platform.announcePlatformUpgrade(
                    '2025.01.0-beta',
                    proxies,
                    implementations
                );
            }

            vm.prank(multisig);
            platform.announcePlatformUpgrade(
                '2025.01.0-beta',
                proxies,
                implementations
            );

            assertEq(platform.pendingPlatformUpgrade().proxies[0], address(proxy));
            assertEq(platform.pendingPlatformUpgrade().newImplementations[0], address(vaultImplementationUpgrade));

            platform.cancelUpgrade();
            assertEq(platform.pendingPlatformUpgrade().proxies.length, 0);

            vm.prank(multisig);
            platform.announcePlatformUpgrade(
                '2025.01.0-beta',
                proxies,
                implementations
            );

            skip(30 minutes);

            vm.expectRevert(bytes("Platform: wait till platformUpgradeTimelock"));
            platform.upgrade();

            skip(30 days);

            platform.upgrade();

            assertEq(proxy.implementation(), address(vaultImplementationUpgrade));
            assertEq(CVault(payable(address(proxy))).VERSION(), "10.99.99");
            assertEq(platform.PLATFORM_VERSION(), '2025.01.0-beta');
        } else {
            vm.expectRevert(bytes("Zero multisig"));
            platform.initialize(multisig, '23.11.0-dev');
        }

    }

    function testSetFees() public {
        //test modifire onlyGovernance
        //result = [FAIL. Reason: Call reverted as expected, but without data]
        //todo - get know reason
        platform.initialize(address(this), '23.11.0-dev');
        address govAddr = platform.governance();

        vm.prank(address(123));
        vm.expectRevert("Controllable: not governance");
        platform.setFees(1,1,1,1); 

        vm.prank(govAddr);
        platform.setFees(6_000, 30_000, 30_000, 0); 
        (uint fee, uint feeShareVaultManager, uint feeShareStrategyLogic, uint feeShareEcosystem) = platform.getFees();
        assertEq(fee, 6_000);
        assertEq(feeShareVaultManager, 30_000);
        assertEq(feeShareStrategyLogic, 30_000);
        assertEq(feeShareEcosystem, 0);
    }

    function testAddRemoveAllowedBBToken() public {
        platform.initialize(address(this), '23.11.0-dev');
        platform.setAllowedBBTokenVaults(address(123), 5);
        platform.setAllowedBBTokenVaults(address(456), 5);

        (address[] memory bbToken, ) = platform.allowedBBTokenVaults();
        assertEq(bbToken[0], address(123));
        assertEq(bbToken[1], address(456));
        platform.removeAllowedBBToken(bbToken[0]);
        
        (bbToken, ) = platform.allowedBBTokenVaults();
        assertEq(bbToken[0], address(456));

        platform.removeAllowedBBToken(bbToken[0]);
        (bbToken, ) = platform.allowedBBTokenVaults();
        assertEq(bbToken.length, 0);
    }

    function testAddRemoveAllowedBoostRewardToken() public {
        platform.initialize(address(this), '23.11.0-dev');
        platform.addAllowedBoostRewardToken(address(123));
        platform.addAllowedBoostRewardToken(address(456));

        vm.expectRevert("Platform: EXIST");
        platform.addAllowedBoostRewardToken(address(456));
        vm.expectRevert("Platform: EXIST");
        platform.removeAllowedBoostRewardToken(address(789));

        address[] memory allowedTokens = platform.allowedBoostRewardTokens();
        assertEq(allowedTokens[0], address(123));
        assertEq(allowedTokens[1], address(456));

        platform.removeAllowedBoostRewardToken(address(123));
        allowedTokens = platform.allowedBoostRewardTokens();
        assertEq(allowedTokens[0], address(456));

        platform.removeAllowedBoostRewardToken(address(456));
        allowedTokens = platform.allowedBoostRewardTokens();
        assertEq(allowedTokens.length, 0);
    }

    function testAddRemoveDefaultBoostRewardToken() public {
        platform.initialize(address(this), '23.11.0-dev');
        platform.addDefaultBoostRewardToken(address(123));
        platform.addDefaultBoostRewardToken(address(456));

        vm.expectRevert("Platform: EXIST");
        platform.addDefaultBoostRewardToken(address(456));
        vm.expectRevert("Platform: EXIST");
        platform.removeDefaultBoostRewardToken(address(789));

        address[] memory defaultTokens = platform.defaultBoostRewardTokens();
        assertEq(defaultTokens[0], address(123));
        assertEq(defaultTokens[1], address(456));

        platform.removeDefaultBoostRewardToken(address(123));
        defaultTokens = platform.defaultBoostRewardTokens();
        assertEq(defaultTokens[0], address(456));

        platform.removeDefaultBoostRewardToken(address(456));
        defaultTokens = platform.defaultBoostRewardTokens();
        assertEq(defaultTokens.length, 0);

    }

    function testGetDexAdapters() public {
        platform.initialize(address(this), '23.11.0-dev');
        platform.addDexAdapter("myId", address(123));
        platform.addDexAdapter("myId2", address(456));

        (string[] memory ids, address[] memory proxies) = platform.getDexAdapters();
        assertEq(ids[0], "myId");
        assertEq(ids[1], "myId2");
        assertEq(proxies[0], address(123));
        assertEq(proxies[1], address(456));

    }

    function testGetData() public {
        platform.initialize(address(this), '23.11.0-dev');

        vm.expectRevert("Platform: need setup");
        {   
            (address[] memory _platformAddresses,,,,,,,) = platform.getData();
            delete _platformAddresses;
        } 

        Proxy proxy = new Proxy();
        proxy.initProxy(address(new Factory()));
        Factory factory = Factory(address(proxy));
        factory.initialize(address(platform));
        platform.setup(
            IPlatform.SetupAddresses({
                factory: address(factory),
                priceReader: address(2),
                swapper: address(3),
                buildingPermitToken: address(4),
                buildingPayPerVaultToken: address(5),
                vaultManager: address(6),
                strategyLogic: address(7),
                aprOracle: address(8),
                targetExchangeAsset: address(9),
                hardWorker: address(10)
            }),
            IPlatform.PlatformSettings({
                networkName: 'Localhost Ethereum',
                networkExtra: CommonLib.bytesToBytes32(abi.encodePacked(bytes3(0x7746d7), bytes3(0x040206))),
                fee: 6_000,
                feeShareVaultManager: 30_000,
                feeShareStrategyLogic: 30_000,
                feeShareEcosystem: 0,
                minInitialBoostPerDay: 30e18, // $30
                minInitialBoostDuration: 30 * 86400 // 30 days
            })
        ); 

        (
            address[] memory platformAddresses,
            string[] memory vaultType,
            bytes32[] memory vaultExtra,
            uint[] memory vaultBuildingPrice,
            string[] memory strategyId,
            bool[] memory isFarmingStrategy,
            string[] memory strategyTokenURI,
            bytes32[] memory strategyExtra
        ) = platform.getData();


        assertEq(platformAddresses[0], platform.factory());
        assertEq(platformAddresses[1], platform.vaultManager());
        assertEq(platformAddresses[2], platform.strategyLogic());
        assertEq(platformAddresses[3], platform.buildingPermitToken());
        assertEq(platformAddresses[4], platform.buildingPayPerVaultToken()); 
        assertEq(vaultType.length, 0); 
        assertEq(vaultExtra.length, 0); 
        assertEq(vaultBuildingPrice.length, 0); 
        assertEq(strategyId.length, 0); 
        assertEq(isFarmingStrategy.length, 0); 
        assertEq(strategyTokenURI.length, 0); 
        assertEq(strategyExtra.length, 0);  
    }
}