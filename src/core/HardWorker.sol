// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/utils/Strings.sol";
import "./base/Controllable.sol";
import "./libs/VaultStatusLib.sol";
import "../interfaces/IPlatform.sol";
import "../interfaces/IFactory.sol";
import "../interfaces/IVaultManager.sol";
import "../interfaces/IVault.sol";
import "../interfaces/IHardWorker.sol";
import "../integrations/gelato/IAutomate.sol";
import "../integrations/gelato/IOpsProxyFactory.sol";
import "../integrations/gelato/ITaskTreasuryUpgradable.sol";

/// @notice HardWork resolver and caller. Primary executor is server script, reserve executor is Gelato Automate.
/// @author Alien Deployer (https://github.com/a17)
contract HardWorker is Controllable, IHardWorker {
    
    /// @dev Version of HardWorker implementation
    string public constant VERSION = "1.0.0";

    address internal constant GELATO_OPS_PROXY_FACTORY = 0xC815dB16D4be6ddf2685C201937905aBf338F5D7;
    address internal constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    mapping(address caller => bool allowed) public dedicatedServerMsgSender;
    address public dedicatedGelatoMsgSender;
    ITaskTreasuryUpgradable public gelatoTaskTreasury;
    bytes32 public gelatoTaskId;
    uint public gelatoMinBalance;
    uint public gelatoDepositAmount;
    uint public delayServer;
    uint public delayGelato;
    uint public maxHwPerCall;
    mapping(address => bool) public excludedVaults;

    function initialize(
        address platform_,
        address gelatoAutomate,
        uint gelatoMinBalance_,
        uint gelatoDepositAmount_
    ) public initializer payable {
        __Controllable_init(platform_);

        delayServer = 11 hours;
        delayGelato = 12 hours;
        emit Delays(11 hours, 12 hours);

        if (gelatoAutomate != address(0)) {
            // setup gelato
            gelatoMinBalance = gelatoMinBalance_;
            gelatoDepositAmount = gelatoDepositAmount_;
            (address _dedicatedGelatoMsgSender, ) = IOpsProxyFactory(GELATO_OPS_PROXY_FACTORY).getProxyOf(address(this));
            dedicatedGelatoMsgSender = _dedicatedGelatoMsgSender;
            IAutomate automate = IAutomate(gelatoAutomate);
            ITaskTreasuryUpgradable _gelatoTaskTreasury = automate.taskTreasury();
            gelatoTaskTreasury = _gelatoTaskTreasury;
            emit DedicatedGelatoMsgSender(address(0), _dedicatedGelatoMsgSender);

            // create Gelato Automate task
            ModuleData memory moduleData = ModuleData({
                modules: new Module[](2),
                args: new bytes[](2)
            });
            moduleData.modules[0] = Module.RESOLVER;
            moduleData.modules[1] = Module.PROXY;
            moduleData.args[0] = abi.encode(address(this), abi.encodeCall(this.checkerGelato, ()));
            moduleData.args[1] = bytes("");
            bytes32 id = automate.createTask(
                address(this),
                abi.encode(this.call.selector),
                moduleData,
                address(0)    
            );
            gelatoTaskId = id;
            emit GelatoTask(id);
        }
    }

    receive() external payable {}

    function setDedicatedServerMsgSender(address sender, bool allowed) external onlyGovernanceOrMultisig {
        require(dedicatedServerMsgSender[sender] != allowed, "HardWorker: nothing to change");
        dedicatedServerMsgSender[sender] = allowed;
        emit DedicatedServerMsgSender(sender, allowed);
    }

    function setDelays(uint delayServer_, uint delayGelato_) external onlyGovernanceOrMultisig {
        require (delayServer != delayServer_ || delayGelato != delayGelato_, "HardWorker: nothing to change");
        delayServer = delayServer_;
        delayGelato = delayGelato_;
        emit Delays(delayServer_, delayGelato_);
    }

    function call(address[] memory vaults) external {
        uint startGas = gasleft();

        bool isServer = dedicatedServerMsgSender[msg.sender];
        require(
            isServer || msg.sender == dedicatedGelatoMsgSender,
            "HardWorker: only dedicated senders"
        );

        if (!isServer) {
            _checkGelatoBalance();
        }

        uint _maxHwPerCall = maxHwPerCall;
        uint vaultsLength = vaults.length;
        uint counter;
        for (uint i; i < vaultsLength; ++i) {
            IVault vault = IVault(vaults[i]);
            try vault.doHardWork() {} catch Error(string memory _err) {
                revert(string(abi.encodePacked("Vault error: 0x", Strings.toHexString(address(vault)), " ", _err)));
            } catch (bytes memory _err) {
                revert(string(abi.encodePacked("Vault low-level error: 0x", Strings.toHexString(address(vault)), " ", string(_err))));
            }
            ++counter;
            if (counter >= _maxHwPerCall) {
                break;
            }
        }

        uint gasUsed = startGas - gasleft();
        uint gasCost = gasUsed * tx.gasprice;

        if (isServer && gasCost > 0 && address(this).balance >= gasCost) {
            (bool success, ) = msg.sender.call{value: gasCost}("");
            require(success, "HardWorker: native transfer failed");
        }

        emit Call(counter, gasUsed, gasCost, isServer);
    }

    function checkerServer() external view returns (bool canExec, bytes memory execPayload) {
        return _checker(delayServer);
    }

    function checkerGelato() external view returns (bool canExec, bytes memory execPayload) {
        return _checker(delayGelato);
    }

    function gelatoBalance() external view returns(uint) {
        return gelatoTaskTreasury.userTokenBalance(address(this), ETH);
    }

    function _checkGelatoBalance() internal {
        ITaskTreasuryUpgradable _treasury = gelatoTaskTreasury;
        uint bal = _treasury.userTokenBalance(address(this), ETH);
        if (bal < gelatoMinBalance) {
            uint contractBal = address(this).balance;
            uint _gelatoDepositAmount = gelatoDepositAmount;
            require(contractBal >= _gelatoDepositAmount, "HardWorker: not enough ETH");
            _treasury.depositFunds{value: _gelatoDepositAmount}(
                address(this),
                ETH,
                0
            );
            emit GelatoDeposit(_gelatoDepositAmount);
        }
    }

    function _checker(uint delay_) internal view returns (bool canExec, bytes memory execPayload) {
        IPlatform _platform = IPlatform(platform());
        IFactory factory = IFactory(_platform.factory());
        address[] memory vaults = IVaultManager(_platform.vaultManager()).vaultAddresses();
        uint len = vaults.length;
        address[] memory vaultsForHardWork = new address[](len);
        uint counter;
        for (uint i; i < len; ++i) {
            if (!excludedVaults[vaults[i]]) {
                IVault vault = IVault(vaults[i]);
                IStrategy strategy = vault.strategy();
                (uint tvl,) = vault.tvl();
                if(
                    tvl > 0
                    && block.timestamp - strategy.lastHardWork() > delay_
                    && factory.vaultStatus(vaults[i]) == VaultStatusLib.ACTIVE
                ) {
                    ++counter;
                    vaultsForHardWork[i] = vaults[i];
                }
            }
        }

        if (counter == 0) {
            return (false, bytes("No ready vaults"));
        } else {
            address[] memory vaultsResult = new address[](counter);
            uint j;
            for (uint i; i < len; ++i) {
                if (vaultsForHardWork[i] != address(0)) {
                    vaultsResult[j] = vaultsForHardWork[i];
                    ++j;
                }
            }

            return (true, abi.encodeWithSelector(HardWorker.call.selector, vaultsResult));
        }
    }

}