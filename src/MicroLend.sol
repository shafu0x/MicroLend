// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20}           from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

interface Oracle { function latestAnswer() external view returns (uint); }

contract MicroLend {
    using SafeTransferLib for ERC20;

    ERC20  public usdcToken;
    Oracle public oracle;

    uint public constant LTV = 75;              // Loan-to-Value ratio in percentage
    uint public constant INTEREST_RATE = 5;     // Annual interest rate in percentage
    uint public constant LIQUIDATION_BONUS = 5; // Liquidation bonus in percentage

    struct Position {
      uint collateralETH; 
      uint debtUSDC;     
      uint lastInterestAccrual; // Timestamp of last interest accrual
    }

    mapping(address => Position) public positions;

    uint public totalCollateralETH;
    uint public totalDebtUSDC;

    constructor(address _usdcToken, address _oracle) { 
      usdcToken = ERC20(_usdcToken);
      oracle    = Oracle(_oracle);
    }

    function supplyCollateral() external payable {
      positions[msg.sender].collateralETH += msg.value;
      totalCollateralETH += msg.value;
    }

    function withdrawCollateral(uint amountETH) external {
      positions[msg.sender].collateralETH -= amountETH;
      totalCollateralETH -= amountETH;

      require(isPositionHealthy(msg.sender), "Position would become unhealthy");
      payable(msg.sender).transfer(amountETH);
    }

    function borrow(uint amountUSDC) external {
      Position storage position = positions[msg.sender];

      uint interest = pendingInterest(position);
      position.debtUSDC += interest;
      position.lastInterestAccrual = block.timestamp;

      position.debtUSDC += amountUSDC;
      totalDebtUSDC += amountUSDC;

      require(isPositionHealthy(msg.sender), "Borrowing exceeds collateral value");

      usdcToken.safeTransfer(msg.sender, amountUSDC);
    }

    function repay(uint amountUSDC) external {
      Position storage position = positions[msg.sender];

      uint interest = pendingInterest(position);
      position.debtUSDC += interest;
      position.lastInterestAccrual = block.timestamp;

      uint repayAmount = amountUSDC > position.debtUSDC ? position.debtUSDC : amountUSDC;
      position.debtUSDC -= repayAmount;
      totalDebtUSDC -= repayAmount;

      usdcToken.safeTransferFrom(msg.sender, address(this), repayAmount);
    }

    function liquidate(address borrower) external {
      require(!isPositionHealthy(borrower), "Position is healthy");

      Position storage position = positions[borrower];

      uint interest = pendingInterest(position);
      position.debtUSDC += interest;
      position.lastInterestAccrual = block.timestamp;

      uint maxRepayAmount = position.debtUSDC * 50 / 100;

      uint collateralValueUSDC = position.collateralETH * (oracle.latestAnswer() * 1e10) / 1e18;
      uint liquidationBonusValue = maxRepayAmount * LIQUIDATION_BONUS / 100;
      uint totalSeizedValueUSDC = maxRepayAmount + liquidationBonusValue;

      if (totalSeizedValueUSDC > collateralValueUSDC) {
          totalSeizedValueUSDC = collateralValueUSDC;
          maxRepayAmount = totalSeizedValueUSDC * 100 / (100 + LIQUIDATION_BONUS);
          liquidationBonusValue = totalSeizedValueUSDC - maxRepayAmount;
      }

      uint seizedETH = totalSeizedValueUSDC * 1e18 / (oracle.latestAnswer() * 1e10);

      position.collateralETH -= seizedETH;
      position.debtUSDC      -= maxRepayAmount;
      totalCollateralETH     -= seizedETH;
      totalDebtUSDC          -= maxRepayAmount;

      payable(msg.sender).transfer(seizedETH);

      usdcToken.safeTransferFrom(msg.sender, address(this), maxRepayAmount);
    }

    function isPositionHealthy(address user) public view returns (bool) {
      Position storage position = positions[user];

      uint collateralValueUSDC = position.collateralETH * (oracle.latestAnswer() * 1e10) / 1e18;
      uint maxBorrowUSDC = collateralValueUSDC * LTV / 100;

      uint debtUSDCWithInterest = position.debtUSDC + pendingInterest(position);

      return debtUSDCWithInterest <= maxBorrowUSDC;
    }

    function pendingInterest(Position storage position) internal view returns (uint) {
      uint timeElapsed = block.timestamp - position.lastInterestAccrual;
      uint interest    = position.debtUSDC * INTEREST_RATE * timeElapsed / 365 days / 100;
      return interest;
    }

    /// @notice Fallback function to accept ETH.
    receive() external payable {}
}
