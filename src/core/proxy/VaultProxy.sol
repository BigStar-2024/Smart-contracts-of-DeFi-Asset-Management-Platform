// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "../../core/base/UpgradeableProxy.sol";
import "../../interfaces/IControllable.sol";
import "../../interfaces/IPlatform.sol";
import "../../interfaces/IFactory.sol";
import "../../interfaces/IVaultProxy.sol";

/// @title EIP1967 Upgradeable proxy implementation for built by factory vaults
contract VaultProxy is UpgradeableProxy, IVaultProxy {
    /// @dev Strategy logic id
    bytes32 private constant _TYPE_SLOT = bytes32(uint256(keccak256("eip1967.vaultProxy.type")) - 1);

    function initProxy(string memory type_) external {
        bytes32 typeHash = keccak256(abi.encodePacked(type_));
        (,address vaultImplementation,,,) = IFactory(msg.sender).vaultConfig(typeHash);
        _init(vaultImplementation);
        bytes32 slot = _TYPE_SLOT;
        assembly {
            sstore(slot, typeHash)
        }
    }

    function upgrade() external {
        require(msg.sender == IPlatform(IControllable(address(this)).platform()).factory(), "Proxy: Forbidden");
        bytes32 typeHash;
        bytes32 slot = _TYPE_SLOT;
        assembly {
            typeHash := sload(slot)
        }
        (,address vaultImplementation,,,) = IFactory(msg.sender).vaultConfig(typeHash);
        _upgradeTo(vaultImplementation);
    }

    function implementation() external view returns (address) {
        return _implementation();
    }

    function VAULT_TYPE_HASH() external view returns (bytes32) {
        bytes32 typeHash;
        bytes32 slot = _TYPE_SLOT;
        assembly {
            typeHash := sload(slot)
        }
        return typeHash;
    }
}