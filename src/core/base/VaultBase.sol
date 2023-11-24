// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./Controllable.sol";
import "../libs/ConstantsLib.sol";
import "../../interfaces/IVault.sol";
import "../../interfaces/IStrategy.sol";
import "../../interfaces/IPriceReader.sol";
import "../../interfaces/IPlatform.sol";
import "../../interfaces/IAprOracle.sol";

/// @notice Base vault implementation.
///         User can deposit and withdraw a changing set of assets managed by the strategy.
///         Start price of vault share is $1.
/// @dev Used by all vault implementations (CVault, RVault, etc)
/// @author Alien Deployer (https://github.com/a17)
/// @author JodsMigel (https://github.com/JodsMigel)
/// @author 0x6c71777172656474 (https://github.com/0x6c71777172656474)
abstract contract VaultBase is Controllable, ERC20Upgradeable, ReentrancyGuardUpgradeable, IVault {
    using SafeERC20 for IERC20;

    //region ----- Constants -----

    /// @dev Version of VaultBase implementation
    string public constant VERSION_VAULT_BASE = '1.0.0';

    /// @dev Delay between deposits/transfers and withdrawals
    uint internal constant _WITHDRAW_REQUEST_BLOCKS = 5;

    /// @dev Initial shares of the vault minted at the first deposit and sent to the dead address.
    uint internal constant _INITIAL_SHARES = 1e15;

    /// @dev Delay for calling strategy.doHardWork() on user deposits
    uint internal constant _MIN_HARDWORK_DELAY = 3600;

    // keccak256(abi.encode(uint256(keccak256("erc7201:stability.VaultBase")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VAULTBASE_STORAGE_LOCATION = 0xd602ae9af1fed726d4890dcf3c81a074ed87a6343646550e5de293c5a9330a00;

    //endregion -- Constants -----

    //region ----- Storage -----

    /// @custom:storage-location erc7201:stability.VaultBase
    struct VaultBaseStorage {
        /// @dev Prevents manipulations with deposit and withdraw in short time.
        ///      For simplification we are setup new withdraw request on each deposit/transfer.
        mapping(address msgSender => uint blockNumber) withdrawRequests;
        /// @inheritdoc IVault
        IStrategy strategy;
        /// @inheritdoc IVault
        uint maxSupply;
        /// @inheritdoc IVault
        uint tokenId;
        /// @inheritdoc IVault
        bool doHardWorkOnDeposit;
        /// @dev Immutable vault type ID
        string _type;
    }


    //endregion -- Storage -----

    //region ----- Init -----
    //slither-disable-next-line naming-convention
    function __VaultBase_init(
        address platform_,
        string memory type_,
        address strategy_,
        string memory name_,
        string memory symbol_,
        uint tokenId_
    ) internal onlyInitializing {
        __Controllable_init(platform_);
        __ERC20_init(name_, symbol_);
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        $._type = type_;
        $.strategy = IStrategy(strategy_);
        $.tokenId = tokenId_;
        __ReentrancyGuard_init();
        $.doHardWorkOnDeposit = true;
    }

    //endregion -- Init -----

    //region ----- Callbacks -----

    /// @dev Need to receive ETH for HardWork and re-balance gas compensation
    receive() external payable {}

    //endregion -- Callbacks -----

    //region ----- Restricted actions -----

    /// @inheritdoc IVault
    function setMaxSupply(uint maxShares) public virtual onlyGovernanceOrMultisig {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        $.maxSupply = maxShares;
        emit MaxSupply(maxShares);
    }

    /// @inheritdoc IVault
    function setDoHardWorkOnDeposit(bool value) external onlyGovernanceOrMultisig {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        $.doHardWorkOnDeposit = value;
        emit DoHardWorkOnDepositChanged($.doHardWorkOnDeposit, value);
    }

    /// @inheritdoc IVault
    function doHardWork() external {
        IPlatform _platform = IPlatform(platform());
        if(msg.sender != _platform.hardWorker()){
            if(!_platform.isOperator(msg.sender))
                revert IncorrectMsgSender();
        }
        uint startGas = gasleft();
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        $.strategy.doHardWork();
        uint gasUsed = startGas - gasleft();
        uint gasCost = gasUsed * tx.gasprice;
        //slither-disable-next-line uninitialized-local
        bool compensated;
        if (gasCost > 0) {
            bool canCompensate = payable(address(this)).balance >= gasCost;
            if (canCompensate) {
                //slither-disable-next-line low-level-calls unused-return
                (bool success, ) = msg.sender.call{value: gasCost}("");
                if(!success) {
                    revert IControllable.ETHTransferFailed();
                }
                compensated = true;
            } else {
                //slither-disable-next-line unused-return
                (uint _tvl,) = tvl();
                // todo #29 IPlatform variable
                if (_tvl < 100e18) {
                    revert NotEnoughBalanceToPay();
                }
            }
        }
        //slither-disable-next-line reentrancy-events
        emit HardWorkGas(gasUsed, gasCost, compensated);
    }

    //endregion -- Restricted actions ----

    //region ----- User actions -----

    /// @inheritdoc IVault
    function depositAssets(address[] memory assets_, uint[] memory amountsMax, uint minSharesOut) external virtual nonReentrant {
        // todo #29 check vault
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        //slither-disable-next-line timestamp
        if ($.doHardWorkOnDeposit) {
            if(block.timestamp > $.strategy.lastHardWork() + _MIN_HARDWORK_DELAY)
                $.strategy.doHardWork();
        }

        uint localTotalSupply = totalSupply();
        uint totalValue = $.strategy.total();
        if(localTotalSupply != 0){
            if(totalValue == 0)
                revert FuseTrigger();
        }
        
        address[] memory assets = $.strategy.assets();
        address underlying = $.strategy.underlying();

        uint len = amountsMax.length;
        if(len != assets_.length){
            revert IControllable.IncorrectArrayLength();
        }

        uint[] memory amountsConsumed;
        uint value;

        if (len == 1) {
            if(underlying != address(0))
                if(underlying == assets_[0]){
                    value = amountsMax[0];
                    IERC20(underlying).safeTransferFrom(msg.sender, address($.strategy), value);
                    (amountsConsumed) = $.strategy.depositUnderlying(value);
                }
        } else {
            (amountsConsumed, value) = $.strategy.previewDepositAssets(assets_, amountsMax);
            // nosemgrep
            for (uint i; i < len; ++i) {
                IERC20(assets[i]).safeTransferFrom(msg.sender, address($.strategy), amountsConsumed[i]);
            }
            value = $.strategy.depositAssets(amountsConsumed);
        }

        if(value == 0){
            revert IControllable.IncorrectZeroArgument();
        }

        uint mintAmount = _mintShares($, localTotalSupply, value, totalValue, amountsConsumed, minSharesOut, assets);

        $.withdrawRequests[msg.sender] = block.number;

        emit DepositAssets(msg.sender, assets_, amountsConsumed, mintAmount);
    }

    /// @inheritdoc IVault
    // slither-disable-next-line reentrancy-no-eth
    function withdrawAssets(address[] memory assets_, uint amountShares, uint[] memory minAssetAmountsOut) external virtual nonReentrant {
        if(amountShares == 0){
            revert IControllable.IncorrectZeroArgument();
        }
        if(amountShares > balanceOf(msg.sender)){
            revert NotEnoughBalanceToPay();
        }
        if(assets_.length != minAssetAmountsOut.length){
            revert IControllable.IncorrectArrayLength();
        }

        VaultBaseStorage storage $ = _getVaultBaseStorage();
        _beforeWithdraw($);

        IStrategy _strategy = $.strategy;
        uint localTotalSupply = totalSupply();
        uint totalValue = _strategy.total();

        uint[] memory amountsOut;
        address underlying = _strategy.underlying();
        bool isUnderlyingWithdrawal = assets_.length == 1 && underlying != address(0) && underlying == assets_[0];

        // fuse is not triggered
        if (totalValue > 0) {
            uint value = amountShares * totalValue / localTotalSupply;
            if (isUnderlyingWithdrawal) {
                amountsOut = new uint[](1);
                amountsOut[0] = value;
                $.strategy.withdrawUnderlying(amountsOut[0], msg.sender);
            } else {
                amountsOut = $.strategy.withdrawAssets(assets_, value, msg.sender);
            }
        } else {
            if (isUnderlyingWithdrawal) {
                amountsOut = new uint[](1);
                amountsOut[0] = amountShares * IERC20(underlying).balanceOf(address(_strategy)) / localTotalSupply;
                $.strategy.withdrawUnderlying(amountsOut[0], msg.sender);
            } else {
                amountsOut = $.strategy.transferAssets(amountShares, localTotalSupply, msg.sender);
            }
        }

        uint len = amountsOut.length;
        // nosemgrep
        for (uint i; i < len; ++i) {
            if(amountsOut[i] < minAssetAmountsOut[i]){
                revert ExceedSlippageExactAsset(assets_[i], amountsOut[i], minAssetAmountsOut[i]);
            }
        }

        _burn(msg.sender, amountShares);

        emit WithdrawAssets(msg.sender, assets_, amountShares, amountsOut);
    }

    //endregion -- User actions ----

    //region ----- View functions -----

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override (Controllable, IERC165) returns (bool) {
        return interfaceId == type(IVault).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IVault
    function vaultType() external view returns (string memory) {
        return _getVaultBaseStorage()._type;
    }

    /// @inheritdoc IVault
    //slither-disable-next-line unused-return
    function price() external view returns (uint price_, bool trusted_) {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        (address[] memory _assets, uint[] memory _amounts) = $.strategy.assetsAmounts();
        IPriceReader priceReader = IPriceReader(IPlatform(platform()).priceReader());
        uint _tvl;
        (_tvl,, trusted_) = priceReader.getAssetsPrice(_assets, _amounts);
        uint localTotalSupply = totalSupply();
        if (localTotalSupply > 0) {
            price_ = _tvl * 1e18 / localTotalSupply;
        }
    }

    /// @inheritdoc IVault
    //slither-disable-next-line unused-return
    function tvl() public view returns (uint tvl_, bool trusted_) {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        (address[] memory _assets, uint[] memory _amounts) = $.strategy.assetsAmounts();
        IPriceReader priceReader = IPriceReader(IPlatform(platform()).priceReader());
        (tvl_,, trusted_) = priceReader.getAssetsPrice(_assets, _amounts);
    }

    /// @inheritdoc IVault
    function previewDepositAssets(address[] memory assets_, uint[] memory amountsMax) external view returns (uint[] memory amountsConsumed, uint sharesOut, uint valueOut) {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        (amountsConsumed, valueOut) = $.strategy.previewDepositAssets(assets_, amountsMax);
        //slither-disable-next-line unused-return
        (sharesOut,) = _calcMintShares(totalSupply(), valueOut, $.strategy.total(), amountsConsumed, $.strategy.assets());
    }

    /// @inheritdoc IVault
    function getApr() external view returns (uint totalApr, uint strategyApr, address[] memory assetsWithApr, uint[] memory assetsAprs) {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        strategyApr = $.strategy.lastApr();
        totalApr = strategyApr;
        address[] memory strategyAssets = $.strategy.assets();
        uint[] memory proportions = $.strategy.getAssetsProportions();
        address underlying = $.strategy.underlying();
        uint assetsLengthTmp = strategyAssets.length;
        if (underlying != address(0)) {
            ++assetsLengthTmp;
        }
        address[] memory queryAprAssets = new address[](assetsLengthTmp);
        uint strategyAssetsLength = strategyAssets.length;
        // nosemgrep
        for (uint i; i < strategyAssetsLength; ++i) {
            queryAprAssets[i] = strategyAssets[i];
        }
        if (underlying != address(0)) {
            queryAprAssets[assetsLengthTmp - 1] = underlying;
        }
        uint[] memory queryAprs = IAprOracle(IPlatform(platform()).aprOracle()).getAprs(queryAprAssets);
        assetsLengthTmp = 0;
        uint queryAprsLength = queryAprs.length;
        // nosemgrep
        for (uint i; i < queryAprsLength; ++i) {
            if (queryAprs[i] > 0) {
                ++assetsLengthTmp;
            }
        }
        assetsWithApr = new address[](assetsLengthTmp);
        assetsAprs = new uint[](assetsLengthTmp);
        //slither-disable-next-line uninitialized-local
        uint k;
        // nosemgrep
        for (uint i; i < queryAprsLength; ++i) {
            if (queryAprs[i] > 0) {
                assetsWithApr[k] = queryAprAssets[i];
                assetsAprs[k] = queryAprs[i];
                if (i < strategyAssetsLength) {
                    totalApr += assetsAprs[k] * proportions[i] / 1e18;
                } else {
                    totalApr += assetsAprs[k];
                }
                ++k;
            }
        }

    }

    /// @inheritdoc IVault
    function strategy() external view returns (IStrategy) {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        return $.strategy;
    }

    /// @inheritdoc IVault
    function maxSupply() external view returns (uint) {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        return $.maxSupply;
    }

    /// @inheritdoc IVault
    function tokenId() external view returns (uint) {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        return $.tokenId;
    }

    /// @inheritdoc IVault
    function doHardWorkOnDeposit() external view returns (bool) {
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        return $.doHardWorkOnDeposit;
    }


    //endregion -- View functions -----

    //region ----- Internal logic -----

    function _getVaultBaseStorage() internal pure returns (VaultBaseStorage storage $) {
        //slither-disable-next-line assembly
        assembly {
            $.slot := VAULTBASE_STORAGE_LOCATION
        }
    }

    /// @dev Minting shares of the vault to the user's address when he deposits funds into the vault.
    ///
    /// During the first deposit, initial shares are also minted and sent to the dead address.
    /// Initial shares save proportion of value to total supply and share price when all users withdraw all their funds from vault.
    /// It prevent flash loan attacks on users' funds.
    /// Also their presence allows the strategy to work without user funds, providing APR for the logic and the farm, if available.
    /// @param totalSupply_ Total supply of shares before deposit
    /// @param value_ Liquidity value or underlying token amount received after deposit
    /// @param amountsConsumed Amounts of strategy assets consumed during the execution of the deposit.
    ///        Consumed amounts used by calculation of minted amount during the first deposit for setting the first share price to 1 USD.
    /// @param minSharesOut Slippage tolerance. Minimal shares amount which must be received by user after deposit
    /// @return mintAmount Amount of minted shares for the user
    function _mintShares(VaultBaseStorage storage $, uint totalSupply_, uint value_, uint totalValue_, uint[] memory amountsConsumed, uint minSharesOut, address[] memory assets) internal returns (uint mintAmount) {
        uint initialShares;
        (mintAmount, initialShares) = _calcMintShares(totalSupply_, value_,  totalValue_, amountsConsumed, assets);
        uint _maxSupply = $.maxSupply;
        if(_maxSupply != 0){
            if(mintAmount + totalSupply_ > _maxSupply)
                revert ExceedMaxSupply(_maxSupply);
        }
        if(mintAmount < minSharesOut){
            revert ExceedSlippage(mintAmount, minSharesOut);
        }
        if (initialShares > 0) {
            _mint(ConstantsLib.DEAD_ADDRESS, initialShares);
        }

        _mint(msg.sender, mintAmount);
    }

    /// @dev Calculating amount of new shares for given deposited value and totals
    function _calcMintShares(uint totalSupply_, uint value_, uint totalValue_, uint[] memory amountsConsumed, address[] memory assets) internal view returns (uint mintAmount, uint initialShares) {
        if (totalSupply_ > 0) {
            mintAmount = value_ * totalSupply_ / totalValue_;
            initialShares = 0; // hide warning
        } else {
            // calc mintAmount for USD amount of value
            // its setting sharePrice to 1e18
            IPriceReader priceReader = IPriceReader(IPlatform(platform()).priceReader());
            //slither-disable-next-line unused-return
            (mintAmount,,) = priceReader.getAssetsPrice(assets, amountsConsumed);

            // initialShares for saving share price after full withdraw
            initialShares = _INITIAL_SHARES;
            if(mintAmount < initialShares * 1000){
                revert NotEnoughAmountToInitSupply(mintAmount, initialShares * 1000);
            }
            mintAmount -= initialShares;
        }
    }

    function _beforeWithdraw(VaultBaseStorage storage $) internal {
        if($.withdrawRequests[msg.sender] + _WITHDRAW_REQUEST_BLOCKS >= block.number){
            revert WaitAFewBlocks();
        }
        $.withdrawRequests[msg.sender] = block.number;
    }

    function _update(
        address from,
        address to,
        uint value
    ) internal virtual override {
        super._update(from, to, value);
        VaultBaseStorage storage $ = _getVaultBaseStorage();
        $.withdrawRequests[from] = block.number;
        $.withdrawRequests[to] = block.number;
    }

    // function _afterTokenTransfer(
    //     address from,
    //     address to,
    //     uint /*amount*/
    // ) internal override {
    //     _withdrawRequests[from] = block.number;
    //     _withdrawRequests[to] = block.number;
    // }

    //endregion -- Internal logic -----
}
