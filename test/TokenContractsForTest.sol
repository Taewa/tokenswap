pragma solidity 0.8.20;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract TokenContract is ERC20{
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}
    
    function mint(address to, uint amount) external {
        _mint(to, amount);
    }
}