// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "./interfaces/IERC20.sol";
import { SafeERC20 } from "./libraries/SafeERC20.sol";

contract MicroLend {
    using SafeERC20 for IERC20;

    IERC20 public usdcToken;

    // Assuming a fixed price: 1 ETH = 3000 USDC (USDC has 6 decimals)
    uint256 public constant ETH_USDC_PRICE = 3000 * 1e6;
    uint256 public constant LTV = 75; // Loan-to-Value ratio in percentage
    uint256 public constant INTEREST_RATE = 5; // Annual interest rate in percentage
    uint256 public constant LIQUIDATION_BONUS = 5; // Liquidation bonus in percentage

    struct Position {
        uint256 collateralETH; // Collateral amount in ETH
        uint256 debtUSDC;      // Debt amount in USDC
        uint256 lastInterestAccrual; // Timestamp of last interest accrual
    }

    mapping(address => Position) public positions;

    uint256 public totalCollateralETH;
    uint256 public totalDebtUSDC;

    event SupplyCollateral(address indexed user, uint256 amountETH);
    event WithdrawCollateral(address indexed user, uint256 amountETH);
    event Borrow(address indexed user, uint256 amountUSDC);
    event Repay(address indexed user, uint256 amountUSDC);
    event Liquidate(
        address indexed liquidator,
        address indexed borrower,
        uint256 repaidAmountUSDC,
        uint256 seizedAmountETH
    );

    constructor(address _usdcToken) {
        usdcToken = IERC20(_usdcToken);
    }

    /// @notice Supply ETH as collateral.
    function supplyCollateral() external payable {
        require(msg.value > 0, "Must send ETH");

        positions[msg.sender].collateralETH += msg.value;
        totalCollateralETH += msg.value;

        emit SupplyCollateral(msg.sender, msg.value);
    }

    /// @notice Withdraw ETH collateral if position remains healthy.
    function withdrawCollateral(uint256 amountETH) external {
        require(amountETH > 0, "Amount must be > 0");
        require(positions[msg.sender].collateralETH >= amountETH, "Not enough collateral");

        // Update collateral
        positions[msg.sender].collateralETH -= amountETH;
        totalCollateralETH -= amountETH;

        // Ensure position remains healthy
        require(isPositionHealthy(msg.sender), "Position would become unhealthy");

        // Transfer ETH back to user
        payable(msg.sender).transfer(amountETH);

        emit WithdrawCollateral(msg.sender, amountETH);
    }

    /// @notice Borrow USDC against your ETH collateral.
    function borrow(uint256 amountUSDC) external {
        require(amountUSDC > 0, "Amount must be > 0");

        Position storage position = positions[msg.sender];

        // Accrue interest
        uint256 interest = calculateInterest(position);
        position.debtUSDC += interest;
        position.lastInterestAccrual = block.timestamp;

        // Update debt
        position.debtUSDC += amountUSDC;
        totalDebtUSDC += amountUSDC;

        // Ensure position is healthy after borrowing
        require(isPositionHealthy(msg.sender), "Borrowing exceeds collateral value");

        // Transfer USDC to user
        usdcToken.safeTransfer(msg.sender, amountUSDC);

        emit Borrow(msg.sender, amountUSDC);
    }

    /// @notice Repay your USDC debt.
    function repay(uint256 amountUSDC) external {
        require(amountUSDC > 0, "Amount must be > 0");

        Position storage position = positions[msg.sender];

        // Accrue interest
        uint256 interest = calculateInterest(position);
        position.debtUSDC += interest;
        position.lastInterestAccrual = block.timestamp;

        // Update debt
        uint256 repayAmount = amountUSDC > position.debtUSDC ? position.debtUSDC : amountUSDC;
        position.debtUSDC -= repayAmount;
        totalDebtUSDC -= repayAmount;

        // Transfer USDC from user
        usdcToken.safeTransferFrom(msg.sender, address(this), repayAmount);

        emit Repay(msg.sender, repayAmount);
    }

    /// @notice Liquidate an undercollateralized position.
    function liquidate(address borrower) external {
        require(!isPositionHealthy(borrower), "Position is healthy");

        Position storage position = positions[borrower];

        // Accrue interest
        uint256 interest = calculateInterest(position);
        position.debtUSDC += interest;
        position.lastInterestAccrual = block.timestamp;

        // Calculate max repayable debt (50% of total debt for this example)
        uint256 maxRepayAmount = position.debtUSDC * 50 / 100;

        // Calculate collateral to seize with liquidation bonus
        uint256 collateralValueUSDC = position.collateralETH * ETH_USDC_PRICE / 1e18;
        uint256 liquidationBonusValue = maxRepayAmount * LIQUIDATION_BONUS / 100;
        uint256 totalSeizedValueUSDC = maxRepayAmount + liquidationBonusValue;

        // Adjust if collateral is insufficient
        if (totalSeizedValueUSDC > collateralValueUSDC) {
            totalSeizedValueUSDC = collateralValueUSDC;
            maxRepayAmount = totalSeizedValueUSDC * 100 / (100 + LIQUIDATION_BONUS);
            liquidationBonusValue = totalSeizedValueUSDC - maxRepayAmount;
        }

        // Convert seized collateral value to ETH amount
        uint256 seizedETH = totalSeizedValueUSDC * 1e18 / ETH_USDC_PRICE;

        // Update positions
        position.collateralETH -= seizedETH;
        position.debtUSDC -= maxRepayAmount;
        totalCollateralETH -= seizedETH;
        totalDebtUSDC -= maxRepayAmount;

        // Transfer seized collateral to liquidator
        payable(msg.sender).transfer(seizedETH);

        // Transfer USDC from liquidator
        usdcToken.safeTransferFrom(msg.sender, address(this), maxRepayAmount);

        emit Liquidate(msg.sender, borrower, maxRepayAmount, seizedETH);
    }

    /// @notice Check if a user's position is healthy.
    function isPositionHealthy(address user) public view returns (bool) {
        Position storage position = positions[user];

        uint256 collateralValueUSDC = position.collateralETH * ETH_USDC_PRICE / 1e18;
        uint256 maxBorrowUSDC = collateralValueUSDC * LTV / 100;

        uint256 debtUSDCWithInterest = position.debtUSDC + pendingInterest(position);

        return debtUSDCWithInterest <= maxBorrowUSDC;
    }

    /// @notice Calculate pending interest for a position.
    function pendingInterest(Position storage position) internal view returns (uint256) {
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;
        uint256 interest = position.debtUSDC * INTEREST_RATE * timeElapsed / 365 days / 100;
        return interest;
    }

    /// @notice Calculate accrued interest for a position.
    function calculateInterest(Position storage position) internal view returns (uint256) {
        return pendingInterest(position);
    }

    /// @notice Fallback function to accept ETH.
    receive() external payable {}
}
