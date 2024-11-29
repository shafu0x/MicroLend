// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20}           from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

interface Oracle { function latestAnswer() external view returns (uint); }

contract MicroLend {
    using SafeTransferLib for ERC20;

    ERC20  public usdcToken;
    ERC20  public wethToken;
    Oracle public oracle;

    uint public constant LTV = 75;              // Loan-to-Value ratio in percentage
    uint public constant INTEREST_RATE = 5;     // Annual interest rate in percentage
    uint public constant LIQUIDATION_BONUS = 5; // Liquidation bonus in percentage

    struct Position {
      uint collateral; 
      uint debt;     
      uint lastInterestAccrual;
    }

    mapping(address => Position) public positions;

    uint public totalCollateralETH;
    uint public totalDebtUSDC;

    constructor(address _usdcToken, address _oracle) { 
      usdcToken = ERC20(_usdcToken);
      oracle    = Oracle(_oracle);
    }

    function supply(uint amount) external {
      wethToken.safeTransferFrom(msg.sender, address(this), amount);
      positions[msg.sender].collateral += amount;
      totalCollateralETH += amount;
    }

    function withdraw(uint amount) external {
      positions[msg.sender].collateral -= amount;
      totalCollateralETH -= amount;

      require(isPositionHealthy(msg.sender));
      wethToken.safeTransfer(msg.sender, amount);
    }

    function borrow(uint amountUSDC) external {
      Position storage position = positions[msg.sender];

      uint interest = pendingInterest(position);
      position.debt += interest;
      position.lastInterestAccrual = block.timestamp;

      position.debt += amountUSDC;
      totalDebtUSDC += amountUSDC;

      require(isPositionHealthy(msg.sender));

      usdcToken.safeTransfer(msg.sender, amountUSDC);
    }

    function repay(uint amountUSDC) external {
      Position storage position = positions[msg.sender];

      uint interest = pendingInterest(position);
      position.debt += interest;
      position.lastInterestAccrual = block.timestamp;

      uint repayAmount = amountUSDC > position.debt ? position.debt : amountUSDC;
      position.debt -= repayAmount;
      totalDebtUSDC -= repayAmount;

      usdcToken.safeTransferFrom(msg.sender, address(this), repayAmount);
    }

    function liquidate(address borrower) external {
      require(!isPositionHealthy(borrower));

      Position storage position = positions[borrower];

      uint interest = pendingInterest(position);
      position.debt += interest;
      position.lastInterestAccrual = block.timestamp;

      uint debt = position.debt;
      uint collateralValueUSDC  = position.collateral * (oracle.latestAnswer() * 1e10) / 1e18;
      uint totalSeizedValueUSDC = debt;

      if (totalSeizedValueUSDC > collateralValueUSDC) {
          totalSeizedValueUSDC = collateralValueUSDC;
          debt = totalSeizedValueUSDC;
      }

      uint seizedETH = totalSeizedValueUSDC * 1e18 / (oracle.latestAnswer() * 1e10);

      position.collateral -= seizedETH;
      position.debt       -= debt;
      totalCollateralETH  -= seizedETH;
      totalDebtUSDC       -= debt;

      wethToken.safeTransfer(msg.sender, seizedETH);
      usdcToken.safeTransferFrom(msg.sender, address(this), debt);
    }

    function isPositionHealthy(address user) public view returns (bool) {
      Position storage position = positions[user];
      uint collateralValueUSDC  = position.collateral * (oracle.latestAnswer() * 1e10) / 1e18;
      uint maxBorrowUSDC        = collateralValueUSDC * LTV / 100;
      uint debtUSDCWithInterest = position.debt + pendingInterest(position);
      return debtUSDCWithInterest <= maxBorrowUSDC;
    }

    function pendingInterest(Position storage position) internal view returns (uint) {
      uint timeElapsed = block.timestamp - position.lastInterestAccrual;
      uint interest    = position.debt * INTEREST_RATE * timeElapsed / 365 days / 100;
      return interest;
    }
}
