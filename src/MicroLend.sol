// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20}           from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

interface Oracle { function latestAnswer() external view returns (uint); }

contract LToken is ERC20("Liquidity Token", "LToken", 18) {
  address public manager;

  constructor(address _manager) { manager = _manager; }

  modifier onlyManager() {
    require(manager == msg.sender);
    _;
  }

  function mint(address to,   uint amount) public onlyManager { _mint(to,   amount); }
  function burn(address from, uint amount) public onlyManager { _burn(from, amount); }
}

contract Manager {
    using SafeTransferLib for ERC20;

    ERC20  public usdc;
    ERC20  public weth;
    Oracle public oracle;
    LToken public lToken;

    uint public constant LTV           = 75;
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
      lToken = new LToken(address(this));
    }

    function supply(uint amount) external {
      usdc.safeTransferFrom(msg.sender, address(this), amount);
      uint lTokenAmount;
      lToken.totalSupply() == 0 
        ? lTokenAmount = amount 
        : lTokenAmount = amount * lToken.totalSupply() / usdc.balanceOf(address(this));
      lToken.mint(msg.sender, lTokenAmount);
    }

    function withdraw(uint amount) external {
      uint totalUsdc = usdc.balanceOf(address(this));
      uint usdcAmount = amount * totalUsdc / lToken.totalSupply();
      lToken.burn(msg.sender, amount);
      usdc.safeTransfer(msg.sender, usdcAmount);
    }

    function supplyCollateral(uint amount) external {
      weth.safeTransferFrom(msg.sender, address(this), amount);
      Position storage position = positions[msg.sender];
      if (position.lastInterestAccrual == 0) { position.lastInterestAccrual = block.timestamp; }
      position.collateral += amount;
      totalCollateral     += amount;
    }

    function withdrawCollateral(uint amount) external {
      accrueInterest(msg.sender);
      positions[msg.sender].collateral -= amount;
      totalCollateral                  -= amount;
      require(isPositionHealthy(msg.sender));
      weth.safeTransfer(msg.sender, amount);
    }

    function borrow(uint amount) external {
      accrueInterest(msg.sender);
      Position storage position = positions[msg.sender];
      position.debt += amount;
      totalDebt     += amount;
      require(isPositionHealthy(msg.sender));
      usdc.safeTransfer(msg.sender, amount);
    }

    function repay(uint amount) external {
      accrueInterest(msg.sender);
      Position storage position = positions[msg.sender];
      uint repayAmount = amount > position.debt ? position.debt : amount;
      position.debt -= repayAmount;
      totalDebt     -= repayAmount;
      usdc.safeTransferFrom(msg.sender, address(this), repayAmount);
    }

    function liquidate(address borrower) external {
      accrueInterest(borrower);
      require(!isPositionHealthy(borrower));

      Position storage position = positions[borrower];

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

    function accrueInterest(address user) internal {
      Position storage position = positions[user];
      uint interest = pendingInterest(position);
      position.debt += interest;
      totalDebt     += interest;
      position.lastInterestAccrual = block.timestamp;
    }
}
