  function getPositionMarginRatio(uint256 positionId) external view returns (uint256) {
        Position storage pos = positions[positionId];
        require(pos.collateral > 0, "Position does not exist");

        uint256 currentPrice = getIndexTokenPrice();

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


    LP deposit in seperate vault
    users collateral in seperate vault