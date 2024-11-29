// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20}           from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

interface Oracle { function latestAnswer() external view returns (uint); }

contract MicroLend {
    using SafeTransferLib for ERC20;

    ERC20  public usdc;
    ERC20  public weth;
    Oracle public oracle;

    uint public constant LTV = 75;
    uint public constant INTEREST_RATE = 5;

    struct Position {
      uint collateral; 
      uint debt;     
      uint liquidity;
      uint lastInterestAccrual;
    }

    mapping(address => Position) public positions;

    uint public totalCollateral;
    uint public totalDebt;

    constructor(address _usdc, address _weth, address _oracle) { 
      usdc   = ERC20(_usdc);
      weth   = ERC20(_weth);
      oracle = Oracle(_oracle);
    }

    function supply(uint amount) external {
      usdc.safeTransferFrom(msg.sender, address(this), amount);
      positions[msg.sender].liquidity += amount;
    }

    function withdraw(uint amount) external {
      positions[msg.sender].liquidity -= amount;
      usdc.safeTransfer(msg.sender, amount);
    }

    function supplyCollateral(uint amount) external {
      weth.safeTransferFrom(msg.sender, address(this), amount);
      positions[msg.sender].collateral += amount;
      totalCollateral                  += amount;
    }

    function withdrawCollateral(uint amount) external {
      positions[msg.sender].collateral -= amount;
      totalCollateral                  -= amount;
      require(isPositionHealthy(msg.sender));
      weth.safeTransfer(msg.sender, amount);
    }

    function borrow(uint amount) external {
      Position storage position = positions[msg.sender];

      uint interest = pendingInterest(position);
      position.debt += interest;
      position.lastInterestAccrual = block.timestamp;

      position.debt += amount;
      totalDebt     += amount;

      require(isPositionHealthy(msg.sender));
      usdc.safeTransfer(msg.sender, amount);
    }

    function repay(uint amount) external {
      Position storage position = positions[msg.sender];

      uint interest = pendingInterest(position);
      position.debt += interest;
      position.lastInterestAccrual = block.timestamp;

      uint repayAmount = amount > position.debt ? position.debt : amount;
      position.debt -= repayAmount;
      totalDebt     -= repayAmount;

      usdc.safeTransferFrom(msg.sender, address(this), repayAmount);
    }

    function liquidate(address borrower) external {
      require(!isPositionHealthy(borrower));

      Position storage position = positions[borrower];

      uint interest = pendingInterest(position);
      position.debt += interest;
      position.lastInterestAccrual = block.timestamp;

      uint debt      = position.debt;
      uint seizedETH = debt * 1e18 / (oracle.latestAnswer() * 1e10);

      position.collateral  = 0;
      position.debt        = 0;
      totalCollateral     -= seizedETH;
      totalDebt           -= debt;

      weth.safeTransfer(msg.sender, seizedETH);
      usdc.safeTransferFrom(msg.sender, address(this), debt);
    }

    function isPositionHealthy(address user) public view returns (bool) {
      Position storage position = positions[user];
      uint collateralValue      = position.collateral * (oracle.latestAnswer() * 1e10) / 1e18;
      uint maxBorrow            = collateralValue * LTV / 100;
      uint debtWithInterest     = position.debt + pendingInterest(position);
      return debtWithInterest <= maxBorrow;
    }

    function pendingInterest(Position storage position) internal view returns (uint) {
      uint timeElapsed = block.timestamp - position.lastInterestAccrual;
      uint interest    = position.debt * INTEREST_RATE * timeElapsed / 365 days / 100;
      return interest;
    }
}
