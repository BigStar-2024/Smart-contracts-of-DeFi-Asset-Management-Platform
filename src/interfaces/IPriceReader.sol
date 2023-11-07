// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @dev Combining oracle and DeX spot prices
/// @author Alien Deployer (https://github.com/a17)
/// @author Jude (https://github.com/iammrjude)
interface IPriceReader {
    //region ----- Events -----
    event AdapterAdded(address adapter);
    event AdapterRemoved(address adapter);
    //endregion -- Events -----

    /// @notice Price of asset
    /// @dev Price of 1.0 amount of asset in USD
    /// @param asset Address of asset
    /// @return price USD price with 18 decimals
    /// @return trusted Price from oracle
    function getPrice(address asset) external view returns (uint price, bool trusted);

    /// @notice Get USD price of specified assets and amounts
    /// @param assets_ Addresses of assets
    /// @param amounts_ Amount of asset. Index of asset same as in previous parameter.
    /// @return total Total USD value with 18 decimals
    /// @return assetAmountPrice USD price of asset amount. Index of assetAmountPrice same as in parameters.
    /// @return trusted True if only oracle prices was used for calculation.
    function getAssetsPrice(address[] memory assets_, uint[] memory amounts_) external view returns (uint total, uint[] memory assetAmountPrice, bool trusted);

    /// @notice Add oracle adapter to PriceReader
    /// Only operator (multisig is operator too) can add adapter
    /// @param adapter_ Address of price oracle proxy
    function addAdapter(address adapter_) external;
}
