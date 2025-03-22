// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


contract PerpetualVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    AggregatorV3Interface public immutable priceFeed;
    IERC20 public immutable assetToken;

    // Constants
    uint256 public constant TRADING_FEE = 50; // 0.5% fee
    uint256 public constant LIQUIDATION_FEE = 100; // 1% liquidation reward
    uint256 public constant MAX_LEVERAGE = 10;
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant PRICE_DECIMALS = 1e10; // For price adjustment

    // Configurable parameters
    uint256 public liquidationThreshold = 80; // 80% Collateral Ratio
    uint256 public maxProfitPercent = 1000; // 10% max profit per position as % of collateral
    bool public emergencyMode = false;

    // LP tracking
    mapping(address => uint256) public lpProviderDeposits;
    mapping(address => uint256) public lpRewards;
    address[] private lpProviders;
    mapping(address => bool) private isLpProvider;

    uint256 private accumulatedFees;

    // Position tracking
    struct Position {
        address trader;
        uint256 collateral;
        uint256 size;
        bool isLong;
        uint256 entryPrice;
        uint256 openTimestamp;
    }

    mapping(uint256 => Position) public positions;
    mapping(address => uint256) private userPosition;
    mapping(address => mapping(uint256 => uint256)) private positionIdToIndex;
    uint256 public nextPositionId;

    // Events
    event PositionOpened(uint256 indexed positionId, address trader, uint256 size, bool isLong, uint256 entryPrice);
    event PositionClosed(uint256 indexed positionId, address trader, uint256 profitOrLoss, uint256 exitPrice);
    event PositionLiquidated(uint256 indexed positionId, address liquidator, uint256 reward, uint256 liquidationPrice);
    event LiquidityAdded(address indexed provider, uint256 amount);
    event LiquidityRemoved(address indexed provider, uint256 amount);
    event RewardClaimed(address indexed provider, uint256 amount);
    event EmergencyModeActivated(bool activated);
    event LiquidationThresholdUpdated(uint256 newThreshold);
    event MaxProfitPercentUpdated(uint256 newPercent);

    error CollateralVault_AmountMustBeGreaterThanZero(uint256 amount);
    error CollateralVault_InEmergencyMode();

    constructor(IERC20 _collateralToken, address _priceFeed)
        ERC4626(_collateralToken)
        Ownable(msg.sender)
        ERC20("VICTORY Perpetual Vault", "VKN")
    {
        priceFeed = AggregatorV3Interface(_priceFeed);
        assetToken = IERC20(_collateralToken);
    }

    // Modifiers
    modifier notEmergency() {
        if (emergencyMode) revert CollateralVault_InEmergencyMode();
        _;
    }

    // Vault management functions
    function setEmergencyMode(bool _status) external onlyOwner {
        emergencyMode = _status;
        emit EmergencyModeActivated(_status);
    }

    function setLiquidationThreshold(uint256 _threshold) external onlyOwner {
        require(_threshold > 0 && _threshold < 100, "Invalid liquidation threshold");
        liquidationThreshold = _threshold;
        emit LiquidationThresholdUpdated(_threshold);
    }

    function setMaxProfitPercent(uint256 _percent) external onlyOwner {
        require(_percent > 0, "Invalid max profit percent");
        maxProfitPercent = _percent;
        emit MaxProfitPercentUpdated(_percent);
    }

    // LP functions
    function depositLiquidity(uint256 amount) external nonReentrant notEmergency {
        require(amount > 0, "Amount must be greater than 0");

        if (!isLpProvider[msg.sender]) {
            lpProviders.push(msg.sender);
            isLpProvider[msg.sender] = true;
        }

        lpProviderDeposits[msg.sender] += amount;

        _deposit(msg.sender, msg.sender, amount, amount);

        emit LiquidityAdded(msg.sender, amount);
    }

    function withdrawLiquidity(uint256 amount) external nonReentrant {
        if (amount < 0) revert CollateralVault_AmountMustBeGreaterThanZero(amount);
        require(lpProviderDeposits[msg.sender] >= amount, "Insufficient liquidity of User");

        // Calculate reserves needed for open positions
        uint256 requiredReserves = calculateRequiredReserves();
        uint256 _totalAssets = assetToken.balanceOf(address(this));

        // Ensure sufficient liquidity remains after withdrawal
        require(_totalAssets - amount >= requiredReserves, "Withdrawal would risk vault solvency");

        // Update LP deposit tracking
        lpProviderDeposits[msg.sender] -= amount;

        _withdraw(msg.sender, msg.sender, msg.sender, amount, 0);

        emit LiquidityRemoved(msg.sender, amount);
    }

    function claimLPRewards() external nonReentrant {
        uint256 reward = lpRewards[msg.sender];
        require(reward > 0, "No rewards available");

        lpRewards[msg.sender] = 0;
        assetToken.safeTransfer(msg.sender, reward);

        emit RewardClaimed(msg.sender, reward);
    }

    function distributeLPRewards() external nonReentrant onlyOwner {
        uint256 totalShares = totalSupply();
        require(totalShares > 0, "No shares to distribute to");

        require(accumulatedFees > 0, "No fees to distribute");

        uint256 feesToDistribute = accumulatedFees;
        accumulatedFees = 0;

        // Distribute rewards based on share proportion
        for (uint256 i = 0; i < lpProviders.length; i++) {
            address lp = lpProviders[i];
            if (balanceOf(lp) > 0) {
                uint256 lpShare = (balanceOf(lp) * feesToDistribute) / totalShares;
                lpRewards[lp] += lpShare;
            }
        }
    }

    // Trading functions
    function openPosition(uint256 collateral, uint256 leverage, bool isLong) external nonReentrant notEmergency {
        require(collateral > 0, "Collateral must be greater than 0");
        require(leverage >= 1 && leverage <= MAX_LEVERAGE, "Invalid leverage");

        uint256 size = collateral * leverage;
        // 6e18 * 50 / 10000
        uint256 fee = (size * TRADING_FEE) / BASIS_POINTS;
        uint256 finalSize = size - fee;
        //6e18 - 3e18
        accumulatedFees += fee;
        uint256 price = getLatestPrice();

        assetToken.safeTransferFrom(msg.sender, address(this), collateral);

        positions[nextPositionId] = Position({
            trader: msg.sender,
            collateral: collateral - fee,
            size: finalSize,
            isLong: isLong,
            entryPrice: price,
            openTimestamp: block.timestamp
        });

        userPosition[msg.sender] = nextPositionId;

        emit PositionOpened(nextPositionId, msg.sender, finalSize, isLong, price);
        nextPositionId++;
    }

    function closePosition(uint256 positionId) external nonReentrant {
        Position memory pos = positions[positionId];
        require(pos.trader == msg.sender, "Not position owner");
        require(pos.collateral > 0, "Position already closed");

        uint256 price = getLatestPrice();

        // Calculate PnL
        int256 pnl;
        if (pos.isLong) {
            pnl = (price > pos.entryPrice)
                ? int256((price - pos.entryPrice) * pos.size / pos.entryPrice)
                : -int256((pos.entryPrice - price) * pos.size / pos.entryPrice);
        } else {
            pnl = (price < pos.entryPrice)
                ? int256((pos.entryPrice - price) * pos.size / pos.entryPrice)
                : -int256((price - pos.entryPrice) * pos.size / pos.entryPrice);
        }


        // Cap profit to prevent vault draining
        uint256 maxProfit = (pos.collateral * maxProfitPercent) / BASIS_POINTS;
        if (pnl > int256(maxProfit)) {
            pnl = int256(maxProfit);
        }

        // Calculate payout
        uint256 payout;
        if (pnl >= 0) {
            uint256 profit = uint256(pnl);
            uint256 fee = (profit * TRADING_FEE) / BASIS_POINTS;

            accumulatedFees += fee;
            payout = pos.collateral + profit - fee;
        } 
        else {
            payout = pos.collateral - uint256(-pnl);
        }

        // Process position closure
        delete positions[positionId];
        delete userPosition[msg.sender];

        assetToken.safeTransfer(msg.sender, payout);

        emit PositionClosed(positionId, msg.sender, pnl >= 0 ? uint256(pnl) : uint256(-pnl), price);
    }

    function liquidatePosition(uint256 positionId) external nonReentrant {
        Position storage pos = positions[positionId];
        require(pos.collateral > 0, "Position already closed");

        uint256 currentPrice = getLatestPrice();

        // Calculate unrealized PnL
        int256 unrealizedPnl;
        if (pos.isLong) {
            unrealizedPnl = (currentPrice > pos.entryPrice)
                ? int256((currentPrice - pos.entryPrice) * pos.size / pos.entryPrice)
                : -int256((pos.entryPrice - currentPrice) * pos.size / pos.entryPrice);
        } else {
            unrealizedPnl = (currentPrice < pos.entryPrice)
                ? int256((pos.entryPrice - currentPrice) * pos.size / pos.entryPrice)
                : -int256((currentPrice - pos.entryPrice) * pos.size / pos.entryPrice);
        }

        // Calculate margin ratio
        uint256 effectiveCollateral = unrealizedPnl > 0
            ? pos.collateral + uint256(unrealizedPnl)
            : pos.collateral > uint256(-unrealizedPnl) ? pos.collateral - uint256(-unrealizedPnl) : 0;

        uint256 marginRatio = (effectiveCollateral * 100) / pos.size;

        require(marginRatio < liquidationThreshold, "Position not eligible for liquidation");

        // Process liquidation
        uint256 liquidationReward = (pos.collateral * LIQUIDATION_FEE) / BASIS_POINTS;
        /*uint256 remainingCollateral = */
        pos.collateral > liquidationReward ? pos.collateral - liquidationReward : 0;

        delete positions[positionId];

        if (liquidationReward > 0) {
            assetToken.safeTransfer(msg.sender, liquidationReward);
        }

        emit PositionLiquidated(positionId, msg.sender, liquidationReward, currentPrice);
    }

    //Assuming this is Eth/USD price feed
    function getLatestPrice() public view returns (uint256 price) {
        (, int256 answer,,,) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid price");

        return uint256(answer) * PRICE_DECIMALS;
    }

    function calculateRequiredReserves() public view returns (uint256) {
        uint256 totalRequired = 0;

        for (uint256 i = 0; i < nextPositionId; i++) {
            Position storage pos = positions[i];
            if (pos.collateral > 0) {
                uint256 maxPayout = pos.collateral + ((pos.collateral * maxProfitPercent) / BASIS_POINTS);
                totalRequired += maxPayout;
            }
        }

        return totalRequired;
    }

    function getPositionCount() external view returns (uint256) {
        return nextPositionId;
    }

    function getUserPosition() external view returns (uint256) {
        return userPosition[msg.sender];
    }

    function getAccumulatedFees() external view onlyOwner returns (uint256) {
        return accumulatedFees;
    }

    function getActivePositionIds() external view returns (uint256[] memory) {
        uint256 count = 0;

        // First count active positions
        for (uint256 i = 0; i < nextPositionId; i++) {
            if (positions[i].collateral > 0) {
                count++;
            }
        }

        // Then populate array
        uint256[] memory activeIds = new uint256[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < nextPositionId; i++) {
            if (positions[i].collateral > 0) {
                activeIds[index] = i;
                index++;
            }
        }

        return activeIds;
    }

    function getPositionMarginRatio(uint256 positionId) external view returns (uint256) {
        Position storage pos = positions[positionId];
        require(pos.collateral > 0, "Position does not exist");

        uint256 currentPrice = getLatestPrice();

        // Calculate unrealized PnL
        int256 unrealizedPnl;
        if (pos.isLong) {
            unrealizedPnl = (currentPrice > pos.entryPrice)
                ? int256((currentPrice - pos.entryPrice) * pos.size / pos.entryPrice)
                : -int256((pos.entryPrice - currentPrice) * pos.size / pos.entryPrice);
        } else {
            unrealizedPnl = (currentPrice < pos.entryPrice)
                ? int256((pos.entryPrice - currentPrice) * pos.size / pos.entryPrice)
                : -int256((currentPrice - pos.entryPrice) * pos.size / pos.entryPrice);
        }

        // Calculate effective collateral safely
        uint256 effectiveCollateral;
        if (unrealizedPnl >= 0) {
            effectiveCollateral = pos.collateral + uint256(unrealizedPnl);
        } else {
            uint256 absUnrealizedPnl = uint256(-unrealizedPnl);
            effectiveCollateral = pos.collateral > absUnrealizedPnl ? pos.collateral - absUnrealizedPnl : 0;
        }

        return (effectiveCollateral * 100) / pos.size;
    }
}
