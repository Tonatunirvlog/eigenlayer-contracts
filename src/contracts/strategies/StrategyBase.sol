// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "../interfaces/IStrategyManager.sol";
import "../permissions/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";

/**
 * @title Base implementation of `IStrategy` interface, designed to be inherited from by more complex strategies.
 * @author Layr Labs, Inc.
 * @notice Simple, basic, "do-nothing" Strategy that holds a single underlying token and returns it on withdrawals.
 * Implements minimal versions of the IStrategy functions, this contract is designed to be inherited by
 * more complex strategies, which can then override its functions as necessary.
 * @dev This contract is expressly *not* intended for use with 'fee-on-transfer'-type tokens.
 * Setting the `underlyingToken` to be a fee-on-transfer token may result in improper accounting.
 */
contract StrategyBase is Initializable, Pausable, IStrategy {
    using SafeERC20 for IERC20;

    uint8 internal constant PAUSED_DEPOSITS = 0;
    uint8 internal constant PAUSED_WITHDRAWALS = 1;
    /*
     * as long as at least *some* shares exist, this is the minimum number.
     * i.e. `totalShares` must exist in the set {0, [MIN_NONZERO_TOTAL_SHARES, type(uint256).max]}
    */
    uint96 internal constant MIN_NONZERO_TOTAL_SHARES = 1e9;

    /// @notice EigenLayer's StrategyManager contract
    IStrategyManager public immutable strategyManager;

    /// @notice The underyling token for shares in this Strategy
    IERC20 public underlyingToken;

    /// @notice The total number of extant shares in thie Strategy
    uint256 public totalShares;

    /// @notice Simply checks that the `msg.sender` is the `strategyManager`, which is an address stored immutably at construction.
    modifier onlyStrategyManager() {
        require(msg.sender == address(strategyManager), "StrategyBase.onlyStrategyManager");
        _;
    }

    /// @notice Since this contract is designed to be initializable, the constructor simply sets `strategyManager`, the only immutable variable.
    constructor(IStrategyManager _strategyManager) {
        strategyManager = _strategyManager;
        _disableInitializers();
    }

    /// @notice Sets the `underlyingToken` and `pauserRegistry` for the strategy.
    function initialize(IERC20 _underlyingToken, IPauserRegistry _pauserRegistry) public initializer {
        underlyingToken = _underlyingToken;
        _initializePauser(_pauserRegistry, UNPAUSE_ALL);
    }

    /**
     * @notice Used to deposit tokens into this Strategy
     * @param token is the ERC20 token being deposited
     * @param amount is the amount of token being deposited
     * @dev This function is only callable by the strategyManager contract. It is invoked inside of the strategyManager's
     * `depositIntoStrategy` function, and individual share balances are recorded in the strategyManager as well.
     * @dev Note that the assumption is made that `amount` of `token` has already been transferred directly to this contract
     * (as performed in the StrategyManager's deposit functions). In particular, setting the `underlyingToken` of this contract
     * to be a fee-on-transfer token will break the assumption that the amount this contract *received* of the token is equal to
     * the amount that was input when the transfer was performed (i.e. the amount transferred 'out' of the depositor's balance).
     * @return newShares is the number of new shares issued at the current exchange ratio.
     */
    function deposit(IERC20 token, uint256 amount)
        external
        virtual
        override
        onlyWhenNotPaused(PAUSED_DEPOSITS)
        onlyStrategyManager
        returns (uint256 newShares)
    {
        require(token == underlyingToken, "StrategyBase.deposit: Can only deposit underlyingToken");

        /**
         * @notice calculation of newShares *mirrors* `underlyingToShares(amount)`, but is different since the balance of `underlyingToken`
         * has already been increased due to the `strategyManager` transferring tokens to this strategy prior to calling this function
         */
        if (totalShares == 0) {
            newShares = amount;
        } else {
            uint256 priorTokenBalance = _tokenBalance() - amount;
            if (priorTokenBalance == 0) {
                newShares = amount;
            } else {
                newShares = (amount * totalShares) / priorTokenBalance;
            }
        }

        // checks to ensure correctness / avoid edge case where share rate can be massively inflated as a 'griefing' sort of attack
        require(newShares != 0, "StrategyBase.deposit: newShares cannot be zero");
        uint256 updatedTotalShares = totalShares + newShares;
        require(updatedTotalShares >= MIN_NONZERO_TOTAL_SHARES,
            "StrategyBase.deposit: updated totalShares amount would be nonzero but below MIN_NONZERO_TOTAL_SHARES");

        // update total share amount
        totalShares = updatedTotalShares;
        return newShares;
    }

    /**
     * @notice Used to withdraw tokens from this Strategy, to the `depositor`'s address
     * @param token is the ERC20 token being transferred out
     * @param amountShares is the amount of shares being withdrawn
     * @dev This function is only callable by the strategyManager contract. It is invoked inside of the strategyManager's
     * other functions, and individual share balances are recorded in the strategyManager as well.
     */
    function withdraw(address depositor, IERC20 token, uint256 amountShares)
        external
        virtual
        override
        onlyWhenNotPaused(PAUSED_WITHDRAWALS)
        onlyStrategyManager
    {
        require(token == underlyingToken, "StrategyBase.withdraw: Can only withdraw the strategy token");
        // copy `totalShares` value to memory, prior to any decrease
        uint256 priorTotalShares = totalShares;
        require(
            amountShares <= priorTotalShares,
            "StrategyBase.withdraw: amountShares must be less than or equal to totalShares"
        );

        // Calculate the value that `totalShares` will decrease to as a result of the withdrawal
        uint256 updatedTotalShares = priorTotalShares - amountShares;
        // check to avoid edge case where share rate can be massively inflated as a 'griefing' sort of attack
        require(updatedTotalShares >= MIN_NONZERO_TOTAL_SHARES || updatedTotalShares == 0,
            "StrategyBase.withdraw: updated totalShares amount would be nonzero but below MIN_NONZERO_TOTAL_SHARES");
        // Actually decrease the `totalShares` value
        totalShares = updatedTotalShares;

        /**
         * @notice calculation of amountToSend *mirrors* `sharesToUnderlying(amountShares)`, but is different since the `totalShares` has already
         * been decremented. Specifically, notice how we use `priorTotalShares` here instead of `totalShares`.
         */
        uint256 amountToSend;
        if (priorTotalShares == amountShares) {
            amountToSend = _tokenBalance();
        } else {
            amountToSend = (_tokenBalance() * amountShares) / priorTotalShares;
        }

        underlyingToken.safeTransfer(depositor, amountToSend);
    }

    /**
     * @notice Currently returns a brief string explaining the strategy's goal & purpose, but for more complex
     * strategies, may be a link to metadata that explains in more detail.
     */
    function explanation() external pure virtual override returns (string memory) {
        return "Base Strategy implementation to inherit from for more complex implementations";
    }

    /**
     * @notice Used to convert a number of shares to the equivalent amount of underlying tokens for this strategy.
     * @notice In contrast to `sharesToUnderlying`, this function guarantees no state modifications
     * @param amountShares is the amount of shares to calculate its conversion into the underlying token
     * @dev Implementation for these functions in particular may vary signifcantly for different strategies
     */
    function sharesToUnderlyingView(uint256 amountShares) public view virtual override returns (uint256) {
        if (totalShares == 0) {
            return amountShares;
        } else {
            return (_tokenBalance() * amountShares) / totalShares;
        }
    }

    /**
     * @notice Used to convert a number of shares to the equivalent amount of underlying tokens for this strategy.
     * @notice In contrast to `sharesToUnderlyingView`, this function **may** make state modifications
     * @param amountShares is the amount of shares to calculate its conversion into the underlying token
     * @dev Implementation for these functions in particular may vary signifcantly for different strategies
     */
    function sharesToUnderlying(uint256 amountShares) public view virtual override returns (uint256) {
        return sharesToUnderlyingView(amountShares);
    }

    /**
     * @notice Used to convert an amount of underlying tokens to the equivalent amount of shares in this strategy.
     * @notice In contrast to `underlyingToShares`, this function guarantees no state modifications
     * @param amountUnderlying is the amount of `underlyingToken` to calculate its conversion into strategy shares
     * @dev Implementation for these functions in particular may vary signifcantly for different strategies
     */
    function underlyingToSharesView(uint256 amountUnderlying) public view virtual returns (uint256) {
        uint256 tokenBalance = _tokenBalance();
        if (tokenBalance == 0 || totalShares == 0) {
            return amountUnderlying;
        } else {
            return (amountUnderlying * totalShares) / tokenBalance;
        }
    }

    /**
     * @notice Used to convert an amount of underlying tokens to the equivalent amount of shares in this strategy.
     * @notice In contrast to `underlyingToSharesView`, this function **may** make state modifications
     * @param amountUnderlying is the amount of `underlyingToken` to calculate its conversion into strategy shares
     * @dev Implementation for these functions in particular may vary signifcantly for different strategies
     */
    function underlyingToShares(uint256 amountUnderlying) external view virtual returns (uint256) {
        return underlyingToSharesView(amountUnderlying);
    }

    /**
     * @notice convenience function for fetching the current underlying value of all of the `user`'s shares in
     * this strategy. In contrast to `userUnderlying`, this function guarantees no state modifications
     */
    function userUnderlyingView(address user) external view virtual returns (uint256) {
        return sharesToUnderlyingView(shares(user));
    }

    /**
     * @notice convenience function for fetching the current underlying value of all of the `user`'s shares in
     * this strategy. In contrast to `userUnderlyingView`, this function **may** make state modifications
     */
    function userUnderlying(address user) external virtual returns (uint256) {
        return sharesToUnderlying(shares(user));
    }

    /**
     * @notice convenience function for fetching the current total shares of `user` in this strategy, by
     * querying the `strategyManager` contract
     */
    function shares(address user) public view virtual returns (uint256) {
        return strategyManager.stakerStrategyShares(user, IStrategy(address(this)));
    }

    /// @notice Internal function used to fetch this contract's current balance of `underlyingToken`.
    // slither-disable-next-line dead-code
    function _tokenBalance() internal view virtual returns (uint256) {
        return underlyingToken.balanceOf(address(this));
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[48] private __gap;
}
